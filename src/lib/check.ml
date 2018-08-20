module D = Domain
module Syn = Syntax
type env_entry =
    Term of {term : D.t; tp : D.t; locks : int; is_active : bool}
  | Tick of {locks : int; is_active : bool}
type env = env_entry list

let add_term ~term ~tp env = Term {term; tp; locks = 0; is_active = true} :: env
let add_tick env = Tick {locks = 0; is_active = true} :: env

exception Type_error
exception Cannot_use_var
exception Cannot_synth of Syn.t

let env_to_sem_env env =
  let size = List.length env in
  let rec go i = function
    | [] -> []
    | Term {term; _} :: env -> term :: go (i + 1) env
    | Tick _ :: env -> Tick (size - (i + 1)) :: go (i + 1) env in
  go 0 env

module S = Set.Make(struct type t = int;; let compare = compare end)

let free_vars =
  let open Syntax in
  let rec go min = function
    | Var i -> if min < i then S.singleton (i - min) else S.empty
    | Next t | Later t -> go (min + 1) t
    | Lam (t1, t2) | Let (t1, t2) | Pi (t1, t2) | Sig (t1, t2) | DFix (t1, t2) ->
      S.union (go min t1) (go (min + 1) t2)
    | Pair (t1, t2) | Check (t1, t2) | Ap (t1, t2) | Prev (t1, t2) -> S.union (go min t1) (go min t2)
    | Nat | Zero | Uni _ | Bullet -> S.empty
    | Suc t | Box t | Open t | Shut t | Fst t | Snd t -> go min t
    | NRec (m, zero, suc, n) ->
      go (min + 1) m
      |> S.union (go min zero)
      |> S.union (go (min + 2) suc)
      |> S.union (go min n) in
  go 0

let strip_env support =
  let rec delete_n_locks n = function
    | [] -> []
    | Term {term; tp; is_active; locks} :: env ->
      Term {term; tp; is_active; locks = locks - n} :: delete_n_locks n env
    | Tick {locks; is_active} :: env ->
      Tick {locks = locks - n; is_active} :: delete_n_locks n env in
  let rec go i = function
    | [] -> []
    | Term {term; tp; is_active; _} :: env ->
      Term {term; tp; is_active; locks = 0} :: go (i + 1) env
    | Tick {locks; is_active} :: env ->
      if S.mem i support
      (* Cannot weaken this tick! *)
      then Tick {locks = 0; is_active} :: delete_n_locks locks env
      else Tick {locks = 0; is_active = false} :: go (i + 1) env in
  go 0

let use_tick env i =
  let rec go j = function
    | [] -> []
    | Term {term; tp; is_active; locks} :: env ->
      Term {term; tp; is_active = is_active && j > i; locks} :: go (j + 1) env
    | Tick {is_active; locks} :: env ->
      Tick {is_active = is_active && j > i; locks} :: go (j + 1) env in
  go 0 env

let apply_lock =
  List.map
    (function
      | Tick t -> Tick {t with locks = t.locks + 1}
      | Term t -> Term {t with locks = t.locks + 1})

let get_var env n = match List.nth env n with
  | Term {term = _; tp; locks = 0; is_active = true} -> tp
  | Term _ -> raise Cannot_use_var
  | Tick _ -> raise Cannot_use_var

let get_tick env n = match List.nth env n with
  | Tick {locks = 0; is_active = true} -> ()
  | Term _ -> raise Cannot_use_var
  | Tick _ -> raise Cannot_use_var

let assert_eq_tp env t1 t2 =
  let size = List.length env in
  let q1 = Nbe.read_back_tp size t1 in
  let q2 = Nbe.read_back_tp size t2 in
  if q1 = q2 then () else raise Type_error

let rec check ~env ~term ~tp =
  match term with
  | Syn.Let (def, body) ->
    let def_tp = synth ~env ~term:def in
    let def_val = Nbe.eval def (env_to_sem_env env) in
    check ~env:(add_term ~term:def_val ~tp:def_tp env) ~term:body ~tp
  | Nat ->
    begin
      match tp with
      | D.Uni _ -> ()
      | _ -> raise Type_error
    end
  | Pi (l, r) | Sig (l, r) ->
    check ~env ~term:l ~tp;
    let l_sem = Nbe.eval l (env_to_sem_env env) in
    let var = D.mk_var l_sem (List.length env) in
    check ~env:(add_term ~term:var ~tp:l_sem env) ~term:r ~tp
  | Lam (arg_tp, body) ->
    check_tp ~env ~term:arg_tp;
    let arg_tp_sem = Nbe.eval arg_tp (env_to_sem_env env) in
    let var = D.mk_var arg_tp_sem (List.length env) in
    begin
      match tp with
      | D.Pi (given_arg_tp, clos) ->
        let dest_tp = Nbe.do_clos clos var in
        check ~env:(add_term ~term:var ~tp:arg_tp_sem env) ~term:body ~tp:dest_tp;
        assert_eq_tp env given_arg_tp arg_tp_sem
      | _ -> raise Type_error
    end
  | Pair (left, right) ->
    begin
      match tp with
      | D.Sig (left_tp, right_tp) ->
        check ~env ~term:left ~tp:left_tp;
        let left_sem = Nbe.eval left (env_to_sem_env env) in
        check ~env ~term:right ~tp:(Nbe.do_clos right_tp left_sem)
      | _ -> raise Type_error
    end
  | Later t -> check ~env:(add_tick env) ~term:t ~tp
  | Next t ->
    begin
      match tp with
      | Next clos ->
        let tp = Nbe.do_tick_clos clos (Tick (List.length env)) in
        check ~env:(add_tick env) ~term:t ~tp
      | _ -> raise Type_error
    end
  | Box term -> check ~env:(apply_lock env) ~term ~tp
  | Shut term ->
    begin
      match tp with
      | Box tp -> check ~env:(apply_lock env) ~term ~tp
      | _ -> raise Type_error
    end
  | Uni i ->
    begin
      match tp with
      | Uni j when i < j -> ()
      | _ -> raise Type_error
    end
  | Bullet -> raise Type_error
  | term -> assert_eq_tp env (synth ~env ~term) tp

and synth ~env ~term =
  match term with
  | Syn.Var i -> get_var env i
  | Check (term, tp') ->
    let tp = Nbe.eval tp' (env_to_sem_env env) in
    check ~env ~term ~tp;
    tp
  | Zero -> D.Nat
  | Suc term -> check ~env ~term ~tp:Nat; D.Nat
  | Fst p ->
    begin
      match synth ~env ~term:p with
      | Sig (left_tp, _) -> left_tp
      | _ -> raise Type_error
    end
  | Snd p ->
    begin
      match synth ~env ~term:p with
      | Sig (_, right_tp) ->
        let proj = Nbe.eval (Fst p) (env_to_sem_env env) in
        Nbe.do_clos right_tp proj
      | _ -> raise Type_error
    end
  | Ap (f, a) ->
    begin
      match synth ~env ~term:f with
      | Pi (src, dest) ->
        check ~env ~term:a ~tp:src;
        let a_sem = Nbe.eval a (env_to_sem_env env) in
        Nbe.do_clos dest a_sem
      | _ -> raise Type_error
    end
  | Prev (term, tick) ->
    begin
      match tick with
      | Var i ->
        get_tick env i;
        let i' = List.length env - (i + 1) in
        begin
          match synth ~env:(use_tick env i) ~term with
          | Next clos -> Nbe.do_tick_clos clos (Tick i')
          | _ -> raise Type_error
        end
      | Bullet ->
        begin
          match synth ~env:(apply_lock env) ~term with
          | Next clos -> Nbe.do_tick_clos clos Bullet
          | _ -> raise Type_error
        end
      | _ -> raise Type_error
    end
  | NRec (mot, zero, suc, n) ->
    check ~env ~term:n ~tp:Nat;
    let size = List.length env in
    let var = D.mk_var Nat size in
    check_tp ~env:(add_term ~term:var ~tp:Nat env) ~term:mot;
    let sem_env = env_to_sem_env env in
    let zero_tp = Nbe.eval mot (Zero :: sem_env) in
    let zero_var = D.mk_var zero_tp size in
    let ih_tp = Nbe.eval mot (var :: sem_env) in
    let ih_var = D.mk_var ih_tp (size + 1) in
    let suc_tp = Nbe.eval mot (Suc var :: sem_env) in
    check ~env:(add_term ~term:zero_var ~tp:zero_tp env) ~term:zero ~tp:zero_tp;
    check
      ~env:(add_term ~term:var ~tp:Nat env |> add_term ~term:ih_var ~tp:ih_tp)
      ~term:suc
      ~tp:suc_tp;
    Nbe.eval mot (Nbe.eval n sem_env :: sem_env)
  | Open term ->
    let support = free_vars term in
    let env = strip_env support env in
    begin
      match synth ~env ~term with
      | Box tp -> tp
      | _ -> raise Type_error
    end
  | DFix (tp', body) ->
    let tp'_sem = Nbe.eval tp' (env_to_sem_env env) in
    let next_tp'_sem = D.Next (ConstTickClos tp'_sem) in
    let var = D.mk_var next_tp'_sem (List.length env) in
    check ~env:(add_term ~term:var ~tp:next_tp'_sem env) ~term:body ~tp:tp'_sem;
    next_tp'_sem
  | _ -> raise (Cannot_synth term)

and check_tp ~env ~term =
  match term with
  | Syn.Nat -> ()
  | Uni _ -> ()
  | Box term -> check_tp ~env:(apply_lock env) ~term
  | Later term -> check_tp ~env:(add_tick env) ~term
  | Pi (l, r) | Sig (l, r) ->
    check_tp ~env ~term:l;
    let l_sem = Nbe.eval l (env_to_sem_env env) in
    let var = D.mk_var l_sem (List.length env) in
    check_tp ~env:(add_term ~term:var ~tp:l_sem env) ~term:r
  | Let (def, body) ->
    let def_tp = synth ~env ~term:def in
    let def_val = Nbe.eval def (env_to_sem_env env) in
    check_tp ~env:(add_term ~term:def_val ~tp:def_tp env) ~term:body
  | term ->
    begin
      match synth ~env ~term with
      | D.Uni _ -> ()
      | _ -> raise Type_error
    end