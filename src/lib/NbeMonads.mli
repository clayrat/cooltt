module D := Domain 
module S := Syntax
module St := ElabState

type 'a compute 
type 'a evaluate
type 'a quote

module CmpM : sig 
  include Monad.MonadReaderResult 
    with type 'a m = 'a compute
    with type local := St.t

  val evaluate : D.env -> 'a evaluate -> 'a m
  val read : ElabState.t m
end

module EvM : sig 
  include Monad.MonadReaderResult 
    with type 'a m = 'a evaluate
    with type local := St.t * D.env

  val compute : 'a compute -> 'a m

  val read_global : ElabState.t m
  val read_local : D.env m

  val close_tp : S.tp -> 'n D.tp_clo m
  val close_tm : S.t -> 'n D.tm_clo m
  val push : D.t list -> 'a m -> 'a m
end

module QuM : sig 
  include Monad.MonadReaderResult 
    with type 'a m = 'a quote
    with type local := St.t * int

  val compute : 'a compute -> 'a m

  val read_global : ElabState.t m
  val read_local : int m

  val push : int -> 'a m -> 'a m
end