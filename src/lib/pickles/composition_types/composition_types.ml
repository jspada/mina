open Pickles_types
module Scalar_challenge = Pickles_types.Scalar_challenge
module Bulletproof_challenge = Bulletproof_challenge
module Index = Index
module Digest = Digest
module Spec = Spec
open Core_kernel

let index_to_field_elements (k : 'a Plonk_verification_key_evals.t) ~g =
  let [ g1
      ; g2
      ; g3
      ; g4
      ; g5
      ; g6
      ; g7
      ; g8
      ; g9
      ; g10
      ; g11
      ; g12
      ; g13
      ; g14
      ; g15
      ; g16
      ; g17
      ; g18 ] =
    Plonk_verification_key_evals.to_hlist k
  in
  List.map
    [ g1
    ; g2
    ; g3
    ; g4
    ; g5
    ; g6
    ; g7
    ; g8
    ; g9
    ; g10
    ; g11
    ; g12
    ; g13
    ; g14
    ; g15
    ; g16
    ; g17
    ; g18 ]
    ~f:g
  |> Array.concat

module Dlog_based = struct
  module Proof_state = struct
    module Deferred_values = struct
      module Plonk = struct
        module Minimal = struct
          type ('challenge, 'scalar_challenge) t =
            { alpha: 'scalar_challenge
            ; beta: 'challenge
            ; gamma: 'challenge
            ; zeta: 'scalar_challenge }
          [@@deriving bin_io, sexp, compare, yojson, hlist, hash, eq]
        end

        open Pickles_types

        module In_circuit = struct
          type ('challenge, 'scalar_challenge, 'fp) t =
            { alpha: 'scalar_challenge
            ; beta: 'challenge
            ; gamma: 'challenge
            ; zeta: 'scalar_challenge
            ; perm0: 'fp
            ; perm1: 'fp
            ; gnrc_l: 'fp
            ; gnrc_r: 'fp
            ; gnrc_o: 'fp
            ; psdn0: 'fp
            ; ecad0: 'fp
            ; vbmul0: 'fp
            ; vbmul1: 'fp
            ; endomul0: 'fp
            ; endomul1: 'fp
            ; endomul2: 'fp }
          [@@deriving bin_io, sexp, compare, yojson, hlist, hash, eq, fields]

          let map_challenges t ~f ~scalar =
            { t with
              alpha= scalar t.alpha
            ; beta= f t.beta
            ; gamma= f t.gamma
            ; zeta= scalar t.zeta }

          let map_fields t ~f =
            { t with
              perm0= f t.perm0
            ; perm1= f t.perm1
            ; gnrc_l= f t.gnrc_l
            ; gnrc_r= f t.gnrc_r
            ; gnrc_o= f t.gnrc_o
            ; psdn0= f t.psdn0
            ; ecad0= f t.ecad0
            ; vbmul0= f t.vbmul0
            ; vbmul1= f t.vbmul1
            ; endomul0= f t.endomul0
            ; endomul1= f t.endomul1
            ; endomul2= f t.endomul2 }

          open Snarky_backendless.H_list

          let typ (type f fp) ~challenge ~scalar_challenge
              (fp : (fp, _, f) Snarky_backendless.Typ.t) =
            Snarky_backendless.Typ.of_hlistable
              [ Scalar_challenge.typ scalar_challenge
              ; challenge
              ; challenge
              ; Scalar_challenge.typ scalar_challenge
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp
              ; fp ]
              ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
              ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
        end

        let to_minimal (t : _ In_circuit.t) : _ Minimal.t =
          {alpha= t.alpha; beta= t.beta; zeta= t.zeta; gamma= t.gamma}
      end

      type ( 'plonk
           , 'scalar_challenge
           , 'fp
           , 'fq
           , 'bulletproof_challenges
           , 'index )
           t_ =
        { plonk: 'plonk
        ; combined_inner_product: 'fp
        ; b: 'fp
        ; xi: 'scalar_challenge
        ; bulletproof_challenges: 'bulletproof_challenges
        ; which_branch: 'index }
      [@@deriving bin_io, sexp, compare, yojson, hlist, hash, eq]

      module Minimal = struct
        type ( 'challenge
             , 'scalar_challenge
             , 'fp
             , 'fq
             , 'bulletproof_challenges
             , 'index )
             t =
          ( ('challenge, 'scalar_challenge) Plonk.Minimal.t
          , 'scalar_challenge
          , 'fp
          , 'fq
          , 'bulletproof_challenges
          , 'index )
          t_
        [@@deriving bin_io, sexp, compare, yojson, hash, eq]
      end

      let map_challenges
          { plonk
          ; combined_inner_product
          ; b: 'fp
          ; xi
          ; bulletproof_challenges
          ; which_branch } ~f ~scalar =
        { xi= scalar xi
        ; combined_inner_product
        ; b
        ; plonk
        ; bulletproof_challenges
        ; which_branch }

      module In_circuit = struct
        type ( 'challenge
             , 'scalar_challenge
             , 'fp
             , 'fq
             , 'bulletproof_challenges
             , 'index )
             t =
          ( ('challenge, 'scalar_challenge, 'fp) Plonk.In_circuit.t
          , 'scalar_challenge
          , 'fp
          , 'fq
          , 'bulletproof_challenges
          , 'index )
          t_
        [@@deriving bin_io, sexp, compare, yojson, hash, eq]

        let to_hlist, of_hlist = (t__to_hlist, t__of_hlist)

        let typ (type f fp) ~challenge ~scalar_challenge
            (fp : (fp, _, f) Snarky_backendless.Typ.t) fq index =
          Snarky_backendless.Typ.of_hlistable
            [ Plonk.In_circuit.typ ~challenge ~scalar_challenge fp
            ; fp
            ; fp
            ; Scalar_challenge.typ scalar_challenge
            ; Vector.typ
                (Bulletproof_challenge.typ scalar_challenge)
                Backend.Tick.Rounds.n
            ; index ]
            ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
            ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
      end

      let to_minimal (t : _ In_circuit.t) : _ Minimal.t =
        {t with plonk= Plonk.to_minimal t.plonk}
    end

    module Me_only = struct
      type ('g1, 'bulletproof_challenges) t =
        {sg: 'g1; old_bulletproof_challenges: 'bulletproof_challenges}
      [@@deriving bin_io, sexp, compare, yojson, hlist, hash, eq]

      let to_field_elements {sg; old_bulletproof_challenges}
          ~g1:g1_to_field_elements =
        Array.concat
          [ Vector.to_array old_bulletproof_challenges
            |> Array.concat_map ~f:Vector.to_array
          ; Array.of_list (g1_to_field_elements sg) ]

      let typ g1 chal ~length =
        Snarky_backendless.Typ.of_hlistable
          [g1; Vector.typ chal length]
          ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
          ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
    end

    type ( 'plonk
         , 'scalar_challenge
         , 'fp
         , 'bool
         , 'fq
         , 'me_only
         , 'digest
         , 'bp_chals
         , 'index )
         t_ =
      { deferred_values:
          ( 'plonk
          , 'scalar_challenge
          , 'fp
          , 'fq
          , 'bp_chals
          , 'index )
          Deferred_values.t_
      ; was_base_case: 'bool
      ; sponge_digest_before_evaluations: 'digest
            (* Not needed by other proof system *)
      ; me_only: 'me_only }
    [@@deriving bin_io, sexp, compare, yojson, hlist, hash, eq]

    module Minimal = struct
      type ( 'challenge
           , 'scalar_challenge
           , 'fp
           , 'bool
           , 'fq
           , 'me_only
           , 'digest
           , 'bp_chals
           , 'index )
           t =
        ( ('challenge, 'scalar_challenge) Deferred_values.Plonk.Minimal.t
        , 'scalar_challenge
        , 'fp
        , 'bool
        , 'fq
        , 'me_only
        , 'digest
        , 'bp_chals
        , 'index )
        t_
      [@@deriving bin_io, sexp, compare, yojson, hash, eq]
    end

    module In_circuit = struct
      type ( 'challenge
           , 'scalar_challenge
           , 'fp
           , 'bool
           , 'fq
           , 'me_only
           , 'digest
           , 'bp_chals
           , 'index )
           t =
        ( ( 'challenge
          , 'scalar_challenge
          , 'fp )
          Deferred_values.Plonk.In_circuit.t
        , 'scalar_challenge
        , 'fp
        , 'bool
        , 'fq
        , 'me_only
        , 'digest
        , 'bp_chals
        , 'index )
        t_
      [@@deriving bin_io, sexp, compare, yojson, hash, eq]

      let to_hlist, of_hlist = (t__to_hlist, t__of_hlist)

      let typ (type f fp) ~challenge ~scalar_challenge
          (fp : (fp, _, f) Snarky_backendless.Typ.t) bool fq me_only digest
          index =
        Snarky_backendless.Typ.of_hlistable
          [ Deferred_values.In_circuit.typ ~challenge ~scalar_challenge fp fq
              index
          ; bool
          ; digest
          ; me_only ]
          ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
          ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
    end

    let to_minimal (t : _ In_circuit.t) : _ Minimal.t =
      {t with deferred_values= Deferred_values.to_minimal t.deferred_values}
  end

  module Pass_through = struct
    type ('g, 's, 'sg, 'bulletproof_challenges) t =
      { app_state: 's
      ; dlog_plonk_index:
          'g Dlog_plonk_types.Poly_comm.Without_degree_bound.t
          Plonk_verification_key_evals.t
      ; sg: 'sg
      ; old_bulletproof_challenges: 'bulletproof_challenges }
    [@@deriving sexp]

    let to_field_elements
        {app_state; dlog_plonk_index; sg; old_bulletproof_challenges}
        ~app_state:app_state_to_field_elements ~comm ~g =
      Array.concat
        [ index_to_field_elements ~g:comm dlog_plonk_index
        ; app_state_to_field_elements app_state
        ; Array.of_list (List.concat_map ~f:g (Vector.to_list sg))
        ; Vector.to_array old_bulletproof_challenges
          |> Array.concat_map ~f:Vector.to_array ]

    let to_field_elements_without_index
        {app_state; dlog_plonk_index= _; sg; old_bulletproof_challenges}
        ~app_state:app_state_to_field_elements ~g =
      Array.concat
        [ app_state_to_field_elements app_state
        ; Array.of_list (List.concat_map ~f:g (Vector.to_list sg))
        ; Vector.to_array old_bulletproof_challenges
          |> Array.concat_map ~f:Vector.to_array ]

    open Snarky_backendless.H_list

    let to_hlist {app_state; dlog_plonk_index; sg; old_bulletproof_challenges}
        =
      [app_state; dlog_plonk_index; sg; old_bulletproof_challenges]

    let of_hlist
        ([app_state; dlog_plonk_index; sg; old_bulletproof_challenges] :
          (unit, _) t) =
      {app_state; dlog_plonk_index; sg; old_bulletproof_challenges}

    let typ comm g s chal branching =
      Snarky_backendless.Typ.of_hlistable
        [s; Plonk_verification_key_evals.typ comm; Vector.typ g branching; chal]
        (* TODO: Should this really just be a vector typ of length Rounds.n ?*)
        ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist ~value_to_hlist:to_hlist
        ~value_of_hlist:of_hlist
  end

  module Statement = struct
    type ( 'plonk
         , 'scalar_challenge
         , 'fp
         , 'bool
         , 'fq
         , 'me_only
         , 'digest
         , 'pass_through
         , 'bp_chals
         , 'index )
         t_ =
      { proof_state:
          ( 'plonk
          , 'scalar_challenge
          , 'fp
          , 'bool
          , 'fq
          , 'me_only
          , 'digest
          , 'bp_chals
          , 'index )
          Proof_state.t_
      ; pass_through: 'pass_through }
    [@@deriving bin_io, compare, yojson, sexp, hash, eq]

    module Minimal = struct
      type ( 'challenge
           , 'scalar_challenge
           , 'fp
           , 'bool
           , 'fq
           , 'me_only
           , 'digest
           , 'pass_through
           , 'bp_chals
           , 'index )
           t =
        ( ( 'challenge
          , 'scalar_challenge )
          Proof_state.Deferred_values.Plonk.Minimal.t
        , 'scalar_challenge
        , 'fp
        , 'bool
        , 'fq
        , 'me_only
        , 'digest
        , 'pass_through
        , 'bp_chals
        , 'index )
        t_
      [@@deriving bin_io, compare, yojson, sexp, hash, eq]
    end

    module In_circuit = struct
      type ( 'challenge
           , 'scalar_challenge
           , 'fp
           , 'bool
           , 'fq
           , 'me_only
           , 'digest
           , 'pass_through
           , 'bp_chals
           , 'index )
           t =
        ( ( 'challenge
          , 'scalar_challenge
          , 'fp )
          Proof_state.Deferred_values.Plonk.In_circuit.t
        , 'scalar_challenge
        , 'fp
        , 'bool
        , 'fq
        , 'me_only
        , 'digest
        , 'pass_through
        , 'bp_chals
        , 'index )
        t_
      [@@deriving bin_io, compare, yojson, sexp, hash, eq]

      let spec =
        let open Spec in
        Struct
          [ Vector (B Bool, Nat.N1.n)
          ; Vector (B Field, Nat.N14.n)
          ; Vector (B Challenge, Nat.N2.n)
          ; Vector (Scalar Challenge, Nat.N3.n)
          ; Vector (B Digest, Nat.N3.n)
          ; Vector (B Bulletproof_challenge, Backend.Tick.Rounds.n)
          ; Vector (B Index, Nat.N1.n) ]

      let to_data
          ({ proof_state=
               { deferred_values=
                   { xi
                   ; combined_inner_product
                   ; b
                   ; which_branch
                   ; bulletproof_challenges
                   ; plonk=
                       { alpha
                       ; beta
                       ; gamma
                       ; zeta
                       ; perm0
                       ; perm1
                       ; gnrc_l
                       ; gnrc_r
                       ; gnrc_o
                       ; psdn0
                       ; ecad0
                       ; vbmul0
                       ; vbmul1
                       ; endomul0
                       ; endomul1
                       ; endomul2 } }
               ; was_base_case
               ; sponge_digest_before_evaluations
               ; me_only }
           ; pass_through } :
            _ t) =
        let open Vector in
        let fp =
          [ combined_inner_product
          ; b
          ; perm0
          ; perm1
          ; gnrc_l
          ; gnrc_r
          ; gnrc_o
          ; psdn0
          ; ecad0
          ; vbmul0
          ; vbmul1
          ; endomul0
          ; endomul1
          ; endomul2 ]
        in
        let challenge = [beta; gamma] in
        let scalar_challenge = [alpha; zeta; xi] in
        let bool = [was_base_case] in
        let digest =
          [sponge_digest_before_evaluations; me_only; pass_through]
        in
        let index = [which_branch] in
        Hlist.HlistId.
          [ bool
          ; fp
          ; challenge
          ; scalar_challenge
          ; digest
          ; bulletproof_challenges
          ; index ]

      let of_data
          Hlist.HlistId.
            [ bool
            ; fp
            ; challenge
            ; scalar_challenge
            ; digest
            ; bulletproof_challenges
            ; index ] : _ t =
        let open Vector in
        let [ combined_inner_product
            ; b
            ; perm0
            ; perm1
            ; gnrc_l
            ; gnrc_r
            ; gnrc_o
            ; psdn0
            ; ecad0
            ; vbmul0
            ; vbmul1
            ; endomul0
            ; endomul1
            ; endomul2 ] =
          fp
        in
        let [beta; gamma] = challenge in
        let [alpha; zeta; xi] = scalar_challenge in
        let [was_base_case] = bool in
        let [sponge_digest_before_evaluations; me_only; pass_through] =
          digest
        in
        let [which_branch] = index in
        { proof_state=
            { was_base_case
            ; deferred_values=
                { xi
                ; combined_inner_product
                ; b
                ; which_branch
                ; bulletproof_challenges
                ; plonk=
                    { alpha
                    ; beta
                    ; gamma
                    ; zeta
                    ; perm0
                    ; perm1
                    ; gnrc_l
                    ; gnrc_r
                    ; gnrc_o
                    ; psdn0
                    ; ecad0
                    ; vbmul0
                    ; vbmul1
                    ; endomul0
                    ; endomul1
                    ; endomul2 } }
            ; sponge_digest_before_evaluations
            ; me_only }
        ; pass_through }
    end

    let to_minimal (t : _ In_circuit.t) : _ Minimal.t =
      {t with proof_state= Proof_state.to_minimal t.proof_state}
  end
end

module Pairing_based = struct
  module Plonk_polys = Vector.Nat.N10

  module Openings = struct
    module Evaluations = struct
      module By_point = struct
        type 'fq t = {beta_1: 'fq; beta_2: 'fq; beta_3: 'fq; g_challenge: 'fq}
      end

      type 'fq t = ('fq By_point.t, Plonk_polys.n Vector.s) Vector.t
    end

    module Bulletproof = struct
      include Dlog_plonk_types.Openings.Bulletproof

      module Advice = struct
        (* This is data that can be computed in linear time from the above plus the statement.
        
          It doesn't need to be sent on the wire, but it does need to be provided to the verifier
        *)
        type ('fq, 'g) t = {b: 'fq} [@@deriving hlist]

        let typ fq g =
          let open Snarky_backendless.Typ in
          of_hlistable [fq] ~var_to_hlist:to_hlist ~var_of_hlist:of_hlist
            ~value_to_hlist:to_hlist ~value_of_hlist:of_hlist
      end
    end

    type ('fq, 'g) t =
      {evaluations: 'fq Evaluations.t; proof: ('fq, 'g) Bulletproof.t}
  end

  module Proof_state = struct
    module Deferred_values = struct
      module Plonk = Dlog_based.Proof_state.Deferred_values.Plonk

      type ('plonk, 'scalar_challenge, 'fq, 'bulletproof_challenges) t_ =
        { plonk: 'plonk
        ; combined_inner_product: 'fq
        ; xi: 'scalar_challenge (* 128 bits *)
        ; bulletproof_challenges: 'bulletproof_challenges
        ; b: 'fq }
      [@@deriving bin_io, sexp, compare, yojson]

      module Minimal = struct
        type ('challenge, 'scalar_challenge, 'fq, 'bulletproof_challenges) t =
          ( ('challenge, 'scalar_challenge) Plonk.Minimal.t
          , 'scalar_challenge
          , 'fq
          , 'bulletproof_challenges )
          t_
        [@@deriving bin_io, sexp, compare, yojson]
      end

      module In_circuit = struct
        type ('challenge, 'scalar_challenge, 'fq, 'bulletproof_challenges) t =
          ( ('challenge, 'scalar_challenge, 'fq) Plonk.In_circuit.t
          , 'scalar_challenge
          , 'fq
          , 'bulletproof_challenges )
          t_
        [@@deriving bin_io, sexp, compare, yojson]
      end
    end

    module Pass_through = Dlog_based.Proof_state.Me_only
    module Me_only = Dlog_based.Pass_through

    module Per_proof = struct
      type ( 'plonk
           , 'scalar_challenge
           , 'fq
           , 'bulletproof_challenges
           , 'digest )
           t_ =
        { deferred_values:
            ( 'plonk
            , 'scalar_challenge
            , 'fq
            , 'bulletproof_challenges )
            Deferred_values.t_
        ; sponge_digest_before_evaluations: 'digest }
      [@@deriving bin_io, sexp, compare, yojson]

      module Minimal = struct
        type ( 'challenge
             , 'scalar_challenge
             , 'fq
             , 'bulletproof_challenges
             , 'digest )
             t =
          ( ('challenge, 'scalar_challenge) Deferred_values.Plonk.Minimal.t
          , 'scalar_challenge
          , 'fq
          , 'bulletproof_challenges
          , 'digest )
          t_
        [@@deriving bin_io, sexp, compare, yojson]
      end

      module In_circuit = struct
        type ( 'challenge
             , 'scalar_challenge
             , 'fq
             , 'bulletproof_challenges
             , 'digest )
             t =
          ( ( 'challenge
            , 'scalar_challenge
            , 'fq )
            Deferred_values.Plonk.In_circuit.t
          , 'scalar_challenge
          , 'fq
          , 'bulletproof_challenges
          , 'digest )
          t_
        [@@deriving bin_io, sexp, compare, yojson]

        let spec bp_log2 =
          let open Spec in
          Struct
            [ Vector (B Field, Nat.N14.n)
            ; Vector (B Digest, Nat.N1.n)
            ; Vector (B Challenge, Nat.N2.n)
            ; Vector (Scalar Challenge, Nat.N3.n)
            ; Vector (B Bulletproof_challenge, bp_log2) ]

        let to_data
            ({ deferred_values=
                 { xi
                 ; bulletproof_challenges
                 ; b
                 ; combined_inner_product
                 ; plonk=
                     { alpha
                     ; beta
                     ; gamma
                     ; zeta
                     ; perm0
                     ; perm1
                     ; gnrc_l
                     ; gnrc_r
                     ; gnrc_o
                     ; psdn0
                     ; ecad0
                     ; vbmul0
                     ; vbmul1
                     ; endomul0
                     ; endomul1
                     ; endomul2 } }
             ; sponge_digest_before_evaluations } :
              _ t) =
          let open Vector in
          let fq =
            [ combined_inner_product
            ; b
            ; perm0
            ; perm1
            ; gnrc_l
            ; gnrc_r
            ; gnrc_o
            ; psdn0
            ; ecad0
            ; vbmul0
            ; vbmul1
            ; endomul0
            ; endomul1
            ; endomul2 ]
          in
          let challenge = [beta; gamma] in
          let scalar_challenge = [alpha; zeta; xi] in
          let digest = [sponge_digest_before_evaluations] in
          let open Hlist.HlistId in
          [fq; digest; challenge; scalar_challenge; bulletproof_challenges]

        let of_data
            Hlist.HlistId.
              [ Vector.
                  [ combined_inner_product
                  ; b
                  ; perm0
                  ; perm1
                  ; gnrc_l
                  ; gnrc_r
                  ; gnrc_o
                  ; psdn0
                  ; ecad0
                  ; vbmul0
                  ; vbmul1
                  ; endomul0
                  ; endomul1
                  ; endomul2 ]
              ; Vector.[sponge_digest_before_evaluations]
              ; Vector.[beta; gamma]
              ; Vector.[alpha; zeta; xi]
              ; bulletproof_challenges ] : _ t =
          { deferred_values=
              { xi
              ; bulletproof_challenges
              ; b
              ; combined_inner_product
              ; plonk=
                  { alpha
                  ; beta
                  ; gamma
                  ; zeta
                  ; perm0
                  ; perm1
                  ; gnrc_l
                  ; gnrc_r
                  ; gnrc_o
                  ; psdn0
                  ; ecad0
                  ; vbmul0
                  ; vbmul1
                  ; endomul0
                  ; endomul1
                  ; endomul2 } }
          ; sponge_digest_before_evaluations }
      end
    end

    type ('unfinalized_proofs, 'me_only) t =
      {unfinalized_proofs: 'unfinalized_proofs; me_only: 'me_only}
    [@@deriving bin_io, sexp, compare, yojson]

    let spec unfinalized_proofs me_only =
      let open Spec in
      Struct [unfinalized_proofs; me_only]

    include struct
      open Hlist.HlistId

      let to_data {unfinalized_proofs; me_only} =
        [ Vector.map unfinalized_proofs ~f:(fun (unfinalized, should_verify) ->
              [Per_proof.In_circuit.to_data unfinalized; should_verify] )
        ; me_only ]

      let of_data [unfinalized_proofs; me_only] =
        { unfinalized_proofs=
            Vector.map unfinalized_proofs
              ~f:(fun [unfinalized; should_verify] ->
                (Per_proof.In_circuit.of_data unfinalized, should_verify) )
        ; me_only }
    end

    let typ impl branching fq :
        ( ((_ * _, _) Vector.t, _) t
        , ((_ * _, _) Vector.t, _) t
        , _ )
        Snarky_backendless.Typ.t =
      let unfinalized_proofs =
        let open Spec in
        Vector
          ( Struct [Per_proof.In_circuit.spec Backend.Tock.Rounds.n; B Bool]
          , branching )
      in
      spec unfinalized_proofs (B Spec.Digest)
      |> Spec.typ impl fq ~challenge:`Constrained
           ~scalar_challenge:`Unconstrained
      |> Snarky_backendless.Typ.transport ~there:to_data ~back:of_data
      |> Snarky_backendless.Typ.transport_var ~there:to_data ~back:of_data
  end

  module Statement = struct
    type ('unfinalized_proofs, 'me_only, 'pass_through) t =
      { proof_state: ('unfinalized_proofs, 'me_only) Proof_state.t
      ; pass_through: 'pass_through }
    [@@deriving bin_io, sexp, compare, yojson]

    let to_data {proof_state= {unfinalized_proofs; me_only}; pass_through} =
      let open Hlist.HlistId in
      [ Vector.map unfinalized_proofs ~f:(fun (pp, b) ->
            Hlist.HlistId.[Proof_state.Per_proof.In_circuit.to_data pp; b] )
      ; me_only
      ; pass_through ]

    let of_data Hlist.HlistId.[unfinalized_proofs; me_only; pass_through] =
      { proof_state=
          { unfinalized_proofs=
              Vector.map unfinalized_proofs
                ~f:(fun ([pp; b] : _ Hlist.HlistId.t) ->
                  (Proof_state.Per_proof.In_circuit.of_data pp, b) )
          ; me_only }
      ; pass_through }

    let spec branching bp_log2 =
      let open Spec in
      let per_proof =
        Struct [Proof_state.Per_proof.In_circuit.spec bp_log2; B Bool]
      in
      Struct
        [Vector (per_proof, branching); B Digest; Vector (B Digest, branching)]
  end
end

module Nvector = Vector.With_length
module Wrap_bp_vec = Nvector (Backend.Tock.Rounds)
module Step_bp_vec = Nvector (Backend.Tick.Rounds)

module Challenges_vector = struct
  type 'n t =
    (Backend.Tock.Field.t Snarky_backendless.Cvar.t Wrap_bp_vec.t, 'n) Vector.t

  module Constant = struct
    type 'n t = (Backend.Tock.Field.t Wrap_bp_vec.t, 'n) Vector.t
  end
end
