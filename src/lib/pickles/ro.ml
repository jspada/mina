open Core
open Backend
open Pickles_types
open Import

let ro lab length f =
  let r = ref 0 in
  fun () ->
    incr r ;
    f (Common.bits_random_oracle ~length (sprintf "%s_%d" lab !r))

let fq = ro "fq" Digest.Constant.length Tock.Field.of_bits

let fp = ro "fp" Digest.Constant.length Tick.Field.of_bits

let chal = ro "chal" Challenge.Constant.length Challenge.Constant.of_bits

let scalar_chal () = Scalar_challenge.Scalar_challenge (chal ())
