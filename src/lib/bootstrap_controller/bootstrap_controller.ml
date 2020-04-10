open Core
open Async
open Coda_base
open Coda_state
open Pipe_lib.Strict_pipe
open Coda_transition
open Network_peer

type t =
  { logger: Logger.t
  ; trust_system: Trust_system.t
  ; verifier: Verifier.t
  ; mutable best_seen_transition: External_transition.Initial_validated.t
  ; mutable current_root: External_transition.Initial_validated.t
  ; network: Coda_networking.t }

let worth_getting_root t candidate =
  `Take
  = Consensus.Hooks.select
      ~logger:
        (Logger.extend t.logger
           [ ( "selection_context"
             , `String "Bootstrap_controller.worth_getting_root" ) ])
      ~existing:
        ( t.best_seen_transition
        |> External_transition.Initial_validated.consensus_state )
      ~candidate

let received_bad_proof t host e =
  Trust_system.(
    record t.trust_system t.logger host
      Actions.
        ( Violated_protocol
        , Some
            ( "Bad ancestor proof: $error"
            , [("error", `String (Error.to_string_hum e))] ) ))

let done_syncing_root root_sync_ledger =
  Option.is_some (Sync_ledger.Db.peek_valid_tree root_sync_ledger)

let should_sync ~root_sync_ledger t candidate_state =
  (not @@ done_syncing_root root_sync_ledger)
  && worth_getting_root t candidate_state

let start_sync_job_with_peer ~sender ~root_sync_ledger t peer_best_tip
    peer_root =
  let%bind () =
    Trust_system.(
      record t.trust_system t.logger (fst sender)
        Actions.
          ( Fulfilled_request
          , Some ("Received verified peer root and best tip", []) ))
  in
  t.best_seen_transition <- peer_best_tip ;
  t.current_root <- peer_root ;
  let blockchain_state =
    t.current_root |> External_transition.Initial_validated.blockchain_state
  in
  let expected_staged_ledger_hash =
    blockchain_state |> Blockchain_state.staged_ledger_hash
  in
  let snarked_ledger_hash =
    blockchain_state |> Blockchain_state.snarked_ledger_hash
  in
  return
  @@
  match
    Sync_ledger.Db.new_goal root_sync_ledger
      (Frozen_ledger_hash.to_ledger_hash snarked_ledger_hash)
      ~data:
        ( External_transition.Initial_validated.state_hash t.current_root
        , sender
        , expected_staged_ledger_hash )
      ~equal:(fun (hash1, _, _) (hash2, _, _) -> State_hash.equal hash1 hash2)
  with
  | `New ->
      `Syncing_new_snarked_ledger
  | `Update_data ->
      `Updating_root_transition
  | `Repeat ->
      `Ignored

let on_transition t ~sender:(host, peer_id) ~root_sync_ledger
    (candidate_transition : External_transition.t) =
  let candidate_state =
    External_transition.consensus_state candidate_transition
  in
  if not @@ should_sync ~root_sync_ledger t candidate_state then
    Deferred.return `Ignored
  else
    match%bind
      Coda_networking.get_ancestry t.network peer_id candidate_state
    with
    | Error e ->
        Logger.error t.logger ~module_:__MODULE__ ~location:__LOC__
          ~metadata:[("error", `String (Error.to_string_hum e))]
          !"Could not get the proof of the root transition from the network: \
            $error" ;
        Deferred.return `Ignored
    | Ok peer_root_with_proof -> (
        match%bind
          Sync_handler.Root.verify ~logger:t.logger ~verifier:t.verifier
            candidate_state peer_root_with_proof.data
        with
        | Ok (`Root root, `Best_tip best_tip) ->
            if done_syncing_root root_sync_ledger then return `Ignored
            else
              start_sync_job_with_peer ~sender:(host, peer_id)
                ~root_sync_ledger t best_tip root
        | Error e ->
            return (received_bad_proof t host e |> Fn.const `Ignored) )

let sync_ledger t ~root_sync_ledger ~transition_graph ~sync_ledger_reader =
  let query_reader = Sync_ledger.Db.query_reader root_sync_ledger in
  let response_writer = Sync_ledger.Db.answer_writer root_sync_ledger in
  Coda_networking.glue_sync_ledger t.network query_reader response_writer ;
  Reader.iter sync_ledger_reader ~f:(fun incoming_transition ->
      let ({With_hash.data= transition; hash}, _)
            : External_transition.Initial_validated.t =
        Envelope.Incoming.data incoming_transition
      in
      let previous_state_hash = External_transition.parent_hash transition in
      let sender = Envelope.Incoming.remote_sender_exn incoming_transition in
      Transition_cache.add transition_graph ~parent:previous_state_hash
        incoming_transition ;
      (* TODO: Efficiently limiting the number of green threads in #1337 *)
      if worth_getting_root t (External_transition.consensus_state transition)
      then (
        Logger.trace t.logger
          !"Added the transition from sync_ledger_reader into cache"
          ~location:__LOC__ ~module_:__MODULE__
          ~metadata:
            [ ("state_hash", State_hash.to_yojson hash)
            ; ("external_transition", External_transition.to_yojson transition)
            ] ;
        Deferred.ignore @@ on_transition t ~sender ~root_sync_ledger transition )
      else Deferred.unit )

(* We conditionally ask other peers for their best tip. This is for testing
   eager bootstrapping and the regular functionalities of bootstrapping in
   isolation *)
let run ~logger ~trust_system ~verifier ~network ~consensus_local_state
    ~transition_reader ~persistent_root ~persistent_frontier
    ~initial_root_transition ~genesis_state_hash ~genesis_ledger =
  let rec loop () =
    let sync_ledger_reader, sync_ledger_writer =
      create ~name:"sync ledger pipe"
        (Buffered (`Capacity 50, `Overflow Crash))
    in
    don't_wait_for
      (transfer_while_writer_alive transition_reader sync_ledger_writer
         ~f:Fn.id) ;
    let initial_root_transition =
      initial_root_transition
      |> External_transition.Validation.reset_frontier_dependencies_validation
      |> External_transition.Validation.reset_staged_ledger_diff_validation
    in
    let t =
      { network
      ; logger
      ; trust_system
      ; verifier
      ; best_seen_transition= initial_root_transition
      ; current_root= initial_root_transition }
    in
    let transition_graph = Transition_cache.create () in
    let temp_persistent_root_instance =
      Transition_frontier.Persistent_root.create_instance_exn persistent_root
    in
    let temp_snarked_ledger =
      Transition_frontier.Persistent_root.Instance.snarked_ledger
        temp_persistent_root_instance
    in
    let%bind hash, (sender_host, sender_peer_id), expected_staged_ledger_hash =
      let root_sync_ledger =
        Sync_ledger.Db.create temp_snarked_ledger ~logger:t.logger
          ~trust_system
      in
      don't_wait_for
        (sync_ledger t ~root_sync_ledger ~transition_graph ~sync_ledger_reader) ;
      (* We ignore the resulting ledger returned here since it will always
       * be the same as the ledger we started with because we are syncing
       * a db ledger. *)
      let%map _, data = Sync_ledger.Db.valid_tree root_sync_ledger in
      Sync_ledger.Db.destroy root_sync_ledger ;
      data
    in
    let%bind staged_ledger_aux_result =
      let open Deferred.Or_error.Let_syntax in
      let%bind ( scan_state
               , expected_merkle_root
               , pending_coinbases
               , _protocol_states ) =
        Coda_networking.get_staged_ledger_aux_and_pending_coinbases_at_hash
          t.network sender_peer_id hash
      in
      let received_staged_ledger_hash =
        Staged_ledger_hash.of_aux_ledger_and_coinbase_hash
          (Staged_ledger.Scan_state.hash scan_state)
          expected_merkle_root pending_coinbases
      in
      Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
        ~metadata:
          [ ( "expected_staged_ledger_hash"
            , Staged_ledger_hash.to_yojson expected_staged_ledger_hash )
          ; ( "received_staged_ledger_hash"
            , Staged_ledger_hash.to_yojson received_staged_ledger_hash ) ]
        "Comparing $expected_staged_ledger_hash to $received_staged_ledger_hash" ;
      let%bind new_root =
        t.current_root
        |> External_transition.skip_frontier_dependencies_validation
             `This_transition_belongs_to_a_detached_subtree
        |> External_transition.validate_staged_ledger_hash
             (`Staged_ledger_already_materialized received_staged_ledger_hash)
        |> Result.map_error ~f:(fun _ ->
               Error.of_string "received faulty scan state from peer" )
        |> Deferred.return
      in
      (* Construct the staged ledger before constructing the transition
       * frontier in order to verify the scan state we received.
       * TODO: reorganize the code to avoid doing this twice (#3480)  *)
      let%map _ =
        let open Deferred.Let_syntax in
        let temp_mask = Ledger.of_database temp_snarked_ledger in
        let%map result =
          Staged_ledger.of_scan_state_pending_coinbases_and_snarked_ledger
            ~logger ~verifier ~scan_state ~snarked_ledger:temp_mask
            ~expected_merkle_root ~pending_coinbases
        in
        ignore (Ledger.Maskable.unregister_mask_exn temp_mask) ;
        result
      in
      (scan_state, pending_coinbases, new_root)
    in
    Transition_frontier.Persistent_root.Instance.destroy
      temp_persistent_root_instance ;
    match staged_ledger_aux_result with
    | Error e ->
        let%bind () =
          Trust_system.(
            record t.trust_system t.logger sender_host
              Actions.
                ( Outgoing_connection_error
                , Some
                    ( "Can't find scan state from the peer or received faulty \
                       scan state from the peer."
                    , [] ) ))
        in
        Logger.error logger ~module_:__MODULE__ ~location:__LOC__
          ~metadata:
            [ ("error", `String (Error.to_string_hum e))
            ; ("state_hash", State_hash.to_yojson hash)
            ; ( "expected_staged_ledger_hash"
              , Staged_ledger_hash.to_yojson expected_staged_ledger_hash ) ]
          "Failed to find scan state for the transition with hash $state_hash \
           from the peer or received faulty scan state: $error. Retry \
           bootstrap" ;
        Writer.close sync_ledger_writer ;
        loop ()
    | Ok (scan_state, pending_coinbase, new_root) -> (
        let%bind () =
          Trust_system.(
            record t.trust_system t.logger sender_host
              Actions.
                ( Fulfilled_request
                , Some ("Received valid scan state from peer", []) ))
        in
        let consensus_state =
          t.best_seen_transition
          |> External_transition.Initial_validated.consensus_state
        in
        (* Synchronize consensus local state if necessary *)
        match%bind
          match
            Consensus.Hooks.required_local_state_sync ~consensus_state
              ~local_state:consensus_local_state
          with
          | None ->
              Logger.debug logger ~module_:__MODULE__ ~location:__LOC__
                ~metadata:
                  [ ( "local_state"
                    , Consensus.Data.Local_state.to_yojson
                        consensus_local_state )
                  ; ( "consensus_state"
                    , Consensus.Data.Consensus_state.Value.to_yojson
                        consensus_state ) ]
                "Not synchronizing consensus local state" ;
              Deferred.return @@ Ok ()
          | Some sync_jobs ->
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                "Synchronizing consensus local state" ;
              Consensus.Hooks.sync_local_state
                ~local_state:consensus_local_state ~logger ~trust_system
                ~random_peers:(fun n ->
                  (* This port is completely made up but we only use the peer_id when doing a query, so it shouldn't matter. *)
                  let%map peers = Coda_networking.random_peers t.network n in
                  Network_peer.Peer.create sender_host ~libp2p_port:0
                    ~peer_id:sender_peer_id
                  :: peers )
                ~query_peer:
                  { Consensus.Hooks.Rpcs.query=
                      (fun peer rpc query ->
                        Coda_networking.(
                          query_peer t.network peer.peer_id
                            (Rpcs.Consensus_rpc rpc) query) ) }
                sync_jobs
        with
        | Error e ->
            Logger.error logger ~module_:__MODULE__ ~location:__LOC__
              ~metadata:[("error", `String (Error.to_string_hum e))]
              "Local state sync failed: $error. Retry bootstrap" ;
            Writer.close sync_ledger_writer ;
            loop ()
        | Ok () ->
            (* Close the old frontier and reload a new on from disk. *)
            let new_root_data =
              Transition_frontier.Root_data.Limited.Stable.V1.
                {transition= new_root; scan_state; pending_coinbase}
            in
            let%bind () =
              Transition_frontier.Persistent_frontier.reset_database_exn
                persistent_frontier ~root_data:new_root_data
            in
            (* TODO: lazy load db in persistent root to avoid unecessary opens like this *)
            Transition_frontier.Persistent_root.(
              with_instance_exn persistent_root ~f:(fun instance ->
                  Instance.set_root_state_hash instance ~genesis_state_hash
                    (External_transition.Validated.state_hash new_root) )) ;
            let%map new_frontier =
              let fail msg =
                failwith
                  ( "failed to initialize transition frontier after \
                     bootstrapping: " ^ msg )
              in
              Transition_frontier.load ~retry_with_fresh_db:false ~logger
                ~verifier ~consensus_local_state ~persistent_root
                ~persistent_frontier ~genesis_state_hash ~genesis_ledger ()
              >>| function
              | Ok frontier ->
                  frontier
              | Error (`Failure msg) ->
                  fail msg
              | Error `Bootstrap_required ->
                  fail
                    "bootstrap still required (indicates logical error in code)"
              | Error `Persistent_frontier_malformed ->
                  fail "persistent frontier was malformed"
            in
            Logger.info logger ~module_:__MODULE__ ~location:__LOC__
              "Bootstrap state: complete." ;
            let collected_transitions =
              Transition_cache.data transition_graph
            in
            let logger =
              Logger.extend logger
                [ ( "context"
                  , `String "Filter collected transitions in bootstrap" ) ]
            in
            let root_consensus_state =
              Transition_frontier.(
                Breadcrumb.consensus_state (root new_frontier))
            in
            let filtered_collected_transitions =
              List.filter collected_transitions ~f:(fun incoming_transition ->
                  let With_hash.{data= transition; _}, _ =
                    Envelope.Incoming.data incoming_transition
                  in
                  `Take
                  = Consensus.Hooks.select ~existing:root_consensus_state
                      ~candidate:
                        (External_transition.consensus_state transition)
                      ~logger )
            in
            Logger.debug logger
              "Sorting filtered transitions by consensus state" ~metadata:[]
              ~location:__LOC__ ~module_:__MODULE__ ;
            let sorted_filtered_collected_transitins =
              List.sort filtered_collected_transitions
                ~compare:
                  (Comparable.lift
                     ~f:(fun incoming_transition ->
                       let With_hash.{data= transition; _}, _ =
                         Envelope.Incoming.data incoming_transition
                       in
                       transition )
                     External_transition.compare)
            in
            (new_frontier, sorted_filtered_collected_transitins) )
  in
  let start_time = Core.Time.now () in
  let%map result = loop () in
  Coda_metrics.(
    Gauge.set Bootstrap.bootstrap_time_ms
      Core.Time.(Span.to_ms @@ diff (now ()) start_time)) ;
  result

let%test_module "Bootstrap_controller tests" =
  ( module struct
    open Pipe_lib

    let max_frontier_length = 10

    let logger = Logger.null ()

    let trust_system = Trust_system.null ()

    let pids = Child_processes.Termination.create_pid_table ()

    let downcast_transition ~sender transition =
      let transition =
        transition
        |> External_transition.Validation
           .reset_frontier_dependencies_validation
        |> External_transition.Validation.reset_staged_ledger_diff_validation
      in
      Envelope.Incoming.wrap ~data:transition
        ~sender:
          (Envelope.Sender.Remote
             (sender.Network_peer.Peer.host, sender.peer_id))

    let downcast_breadcrumb ~sender breadcrumb =
      downcast_transition ~sender
        (Transition_frontier.Breadcrumb.validated_transition breadcrumb)

    let make_non_running_bootstrap ~genesis_root ~network =
      let verifier =
        Async.Thread_safe.block_on_async_exn (fun () ->
            Verifier.create ~logger ~conf_dir:None ~pids )
      in
      let transition =
        genesis_root
        |> External_transition.Validation
           .reset_frontier_dependencies_validation
        |> External_transition.Validation.reset_staged_ledger_diff_validation
      in
      { logger
      ; trust_system
      ; verifier
      ; best_seen_transition= transition
      ; current_root= transition
      ; network }

    let%test_unit "Bootstrap controller caches all transitions it is passed \
                   through the transition_reader" =
      let branch_size = (max_frontier_length * 2) + 2 in
      Quickcheck.test ~trials:1
        (let open Quickcheck.Generator.Let_syntax in
        (* we only need one node for this test, but we need more than one peer so that coda_networking does not throw an error *)
        let%bind fake_network =
          Fake_network.Generator.(
            gen ~max_frontier_length [fresh_peer; fresh_peer])
        in
        let%map make_branch =
          Transition_frontier.Breadcrumb.For_tests.gen_seq
            ~accounts_with_secret_keys:
              (Lazy.force Test_genesis_ledger.accounts)
            branch_size
        in
        let [me; _] = fake_network.peer_networks in
        let branch =
          Async.Thread_safe.block_on_async_exn (fun () ->
              make_branch (Transition_frontier.root me.state.frontier) )
        in
        (fake_network, branch))
        ~f:(fun (fake_network, branch) ->
          let [me; _] = fake_network.peer_networks in
          let genesis_root =
            Transition_frontier.(
              Breadcrumb.validated_transition @@ root me.state.frontier)
          in
          let transition_graph = Transition_cache.create () in
          let sync_ledger_reader, sync_ledger_writer =
            Pipe_lib.Strict_pipe.create ~name:"sync_ledger_reader" Synchronous
          in
          let bootstrap =
            make_non_running_bootstrap ~genesis_root ~network:me.network
          in
          let root_sync_ledger =
            Sync_ledger.Db.create
              (Transition_frontier.root_snarked_ledger me.state.frontier)
              ~logger ~trust_system
          in
          Async.Thread_safe.block_on_async_exn (fun () ->
              let sync_deferred =
                sync_ledger bootstrap ~root_sync_ledger ~transition_graph
                  ~sync_ledger_reader
              in
              let%bind () =
                Deferred.List.iter branch ~f:(fun breadcrumb ->
                    Strict_pipe.Writer.write sync_ledger_writer
                      (downcast_breadcrumb ~sender:me.peer breadcrumb) )
              in
              Strict_pipe.Writer.close sync_ledger_writer ;
              sync_deferred ) ;
          let expected_transitions =
            List.map branch ~f:(fun breadcrumb ->
                Transition_frontier.Breadcrumb.validated_transition breadcrumb
                |> External_transition.Validation.forget_validation )
          in
          let saved_transitions =
            Transition_cache.data transition_graph
            |> List.map ~f:(fun env ->
                   let transition, _ = Envelope.Incoming.data env in
                   transition.data )
          in
          [%test_result: External_transition.Set.t]
            (External_transition.Set.of_list saved_transitions)
            ~expect:(External_transition.Set.of_list expected_transitions) )

    (*
    let run_bootstrap ~timeout_duration ~my_net ~transition_reader ~should_ask_best_tip =
      let open Fake_network in
      let verifier = Async.Thread_safe.block_on_async_exn (fun () -> Verifier.create ~logger ~pids) in
      let persistent_root = Transition_frontier.persistent_root my_net.state.frontier in
      let persistent_frontier = Transition_frontier.persistent_frontier my_net.state.frontier in
      let initial_root_transition = Transition_frontier.(Breadcrumb.validated_transition (root my_net.state.frontier)) in
      let%bind () = Transition_frontier.close my_net.state.frontier in
      Block_time.Timeout.await_exn time_controller ~timeout_duration (
        run ~logger ~verifier ~trust_system ~network:my_net.network
          ~consensus_local_state:my_net.state.consensus_local_state ~transition_reader
          ~should_ask_best_tip ~persistent_root ~persistent_frontier
          ~initial_root_transition)

    let assert_transitions_increasingly_sorted ~root
        (incoming_transitions :
          External_transition.Initial_validated.t Envelope.Incoming.t list) =
      let root =
        With_hash.data @@ fst
        @@ Transition_frontier.Breadcrumb.validated_transition root
      in
      let blockchain_length =
        Fn.compose Consensus.Data.Consensus_state.blockchain_length
          External_transition.consensus_state
      in
      List.fold_result ~init:root incoming_transitions
        ~f:(fun max_acc incoming_transition ->
          let With_hash.{data= transition; _}, _ =
            Envelope.Incoming.data incoming_transition
          in
          let open Result.Let_syntax in
          let%map () =
            Result.ok_if_true
              Coda_numbers.Length.(
                blockchain_length max_acc <= blockchain_length transition)
              ~error:
                (Error.of_string
                   "The blocks are not sorted in increasing order")
          in
          transition )
      |> Or_error.ok_exn |> ignore

    let%test_unit "sync with one node after receiving a transition" =
      Quickcheck.test ~trials:1
        Fake_network.Generator.(gen ~max_frontier_length [fresh_peer; peer_with_branch ~frontier_branch_size:10])
        ~f:(fun fake_network ->
          let [my_net; peer_net] = fake_network.peer_networks in
          let transition_reader, _ =
            Pipe_lib.Strict_pipe.create ~name:(__MODULE__ ^ __LOC__)
              (Buffered (`Capacity 10, `Overflow Drop_head))
          in
          Coda_networking.broadcast_state peer_net.network (
            Transition_frontier.best_tip peer_net.state.frontier
            |> Transition_frontier.Breadcrumb.validated_transition
            |> External_transition.Validation.forget_validation);
          let new_frontier, sorted_external_transitions =
            Async.Thread_safe.block_on_async_exn (fun () ->
              run_bootstrap ~timeout_duration:(Block_time.Span.of_ms 10_000L) ~my_net ~transition_reader ~should_ask_best_tip:false)
          in
          assert_transitions_increasingly_sorted
            ~root:(Transition_frontier.root new_frontier)
            sorted_external_transitions ;
          [%test_result: Ledger_hash.t]
            (Ledger.Db.merkle_root @@ Transition_frontier.root_snarked_ledger new_frontier)
            ~expect:(Ledger.Db.merkle_root @@ Transition_frontier.root_snarked_ledger peer_net.state.frontier))
    *)

    (* TODO: move test to scan state module *)
    (*
    let%test_unit "reconstruct staged_ledgers using of_scan_state_and_snarked_ledger" =
      let pids = Child_processes.Termination.create_pid_table () in
      let num_breadcrumbs = 10 in
      let accounts = Test_genesis_ledger.accounts in
      heartbeat_flag := true ;
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind frontier = create_root_frontier ~logger ~pids accounts in
          let%bind () =
            build_frontier_randomly frontier
              ~gen_root_breadcrumb_builder:
                (gen_linear_breadcrumbs ~logger ~pids ~trust_system
                   ~size:num_breadcrumbs ~accounts_with_secret_keys:accounts)
          in
          Deferred.List.iter (Transition_frontier.all_breadcrumbs frontier)
            ~f:(fun breadcrumb ->
              let staged_ledger =
                Transition_frontier.Breadcrumb.staged_ledger breadcrumb
              in
              let expected_merkle_root =
                Staged_ledger.ledger staged_ledger |> Ledger.merkle_root
              in
              let snarked_ledger =
                Transition_frontier.shallow_copy_root_snarked_ledger frontier
              in
              let scan_state = Staged_ledger.scan_state staged_ledger in
              let pending_coinbases =
                Staged_ledger.pending_coinbase_collection staged_ledger
              in
              let%bind verifier = Verifier.create ~logger ~pids in
              let%map actual_staged_ledger =
                Staged_ledger
                .of_scan_state_pending_coinbases_and_snarked_ledger ~scan_state
                  ~logger ~verifier ~snarked_ledger ~expected_merkle_root
                  ~pending_coinbases
                |> Deferred.Or_error.ok_exn
              in
              heartbeat_flag := false ;
              assert (
                Staged_ledger_hash.equal
                  (Staged_ledger.hash staged_ledger)
                  (Staged_ledger.hash actual_staged_ledger) ) ) )
    *)

    (* TODO: port these tests *)
    (*
    let%test "sync with one node eagerly" =
      Backtrace.elide := false ;
      heartbeat_flag := true ;
      Printexc.record_backtrace true ;
      let pids = Child_processes.Termination.create_pid_table () in
      let num_breadcrumbs = (2 * max_length) + Consensus.Constants.delta + 2 in
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind syncing_frontier, peer, network =
            Network_builder.setup_me_and_a_peer ~logger ~pids ~trust_system
              ~num_breadcrumbs
              ~source_accounts:[List.hd_exn Test_genesis_ledger.accounts]
              ~target_accounts:Test_genesis_ledger.accounts
          in
          let transition_reader, _ = make_transition_pipe () in
          let ledger_db =
            Transition_frontier.For_tests.root_snarked_ledger syncing_frontier
          in
          let%bind run =
            f_with_verifier ~f:Bootstrap_controller.For_tests.run ~logger ~pids
              ~trust_system
          in
          let%map ( new_frontier
                  , (sorted_transitions :
                      External_transition.Initial_validated.t
                      Envelope.Incoming.t
                      list) ) =
            run ~network ~frontier:syncing_frontier ~ledger_db
              ~transition_reader ~should_ask_best_tip:true
          in
          let root = Transition_frontier.(root new_frontier) in
          assert_transitions_increasingly_sorted ~root sorted_transitions ;
          heartbeat_flag := false ;
          Ledger_hash.equal (root_hash new_frontier) (root_hash peer.frontier)
      )

    let%test "when eagerly syncing to multiple nodes, you should sync to the \
              node with the highest transition_frontier" =
      heartbeat_flag := true ;
      let pids = Child_processes.Termination.create_pid_table () in
      let unsynced_peer_num_breadcrumbs = 6 in
      let unsynced_peers_accounts =
        List.take Test_genesis_ledger.accounts
          (List.length Test_genesis_ledger.accounts / 2)
      in
      let synced_peer_num_breadcrumbs = unsynced_peer_num_breadcrumbs * 2 in
      let source_accounts = [List.hd_exn Test_genesis_ledger.accounts] in
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind {me; peers; network} =
            Network_builder.setup ~source_accounts ~logger ~pids ~trust_system
              [ { num_breadcrumbs= unsynced_peer_num_breadcrumbs
                ; accounts= unsynced_peers_accounts }
              ; { num_breadcrumbs= synced_peer_num_breadcrumbs
                ; accounts= Test_genesis_ledger.accounts } ]
          in
          let transition_reader, _ = make_transition_pipe () in
          let ledger_db =
            Transition_frontier.For_tests.root_snarked_ledger me
          in
          let synced_peer = List.nth_exn peers 1 in
          let%bind run =
            f_with_verifier ~f:Bootstrap_controller.For_tests.run ~logger ~pids
              ~trust_system
          in
          let%map ( new_frontier
                  , (sorted_external_transitions :
                      External_transition.Initial_validated.t
                      Envelope.Incoming.t
                      list) ) =
            run ~network ~frontier:me ~ledger_db ~transition_reader
              ~should_ask_best_tip:true
          in
          assert_transitions_increasingly_sorted
            ~root:(Transition_frontier.root new_frontier)
            sorted_external_transitions ;
          heartbeat_flag := false ;
          Ledger_hash.equal (root_hash new_frontier)
            (root_hash synced_peer.frontier) )

    let%test "if we see a new transition that is better than the transition \
              that we are syncing from, than we should retarget our root" =
      Backtrace.elide := false ;
      Printexc.record_backtrace true ;
      heartbeat_flag := true ;
      let pids = Child_processes.Termination.create_pid_table () in
      let small_peer_num_breadcrumbs = 6 in
      let large_peer_num_breadcrumbs = small_peer_num_breadcrumbs * 2 in
      let source_accounts = [List.hd_exn Test_genesis_ledger.accounts] in
      let small_peer_accounts =
        List.take Test_genesis_ledger.accounts
          (List.length Test_genesis_ledger.accounts / 2)
      in
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let large_peer_accounts = Test_genesis_ledger.accounts in
          let%bind {me; peers; network} =
            Network_builder.setup ~source_accounts ~logger ~pids ~trust_system
              [ { num_breadcrumbs= small_peer_num_breadcrumbs
                ; accounts= small_peer_accounts }
              ; { num_breadcrumbs= large_peer_num_breadcrumbs
                ; accounts= large_peer_accounts } ]
          in
          let transition_reader, transition_writer = make_transition_pipe () in
          let small_peer, large_peer =
            (List.nth_exn peers 0, List.nth_exn peers 1)
          in
          let ledger_db =
            Transition_frontier.For_tests.root_snarked_ledger me
          in
          Network_builder.send_transition ~logger ~transition_writer
            ~peer:small_peer
            (get_best_tip_hash small_peer) ;
          (* Have a bit of delay when sending the more recent transition *)
          let%bind () =
            after (Core.Time.Span.of_sec 1.0)
            >>| fun () ->
            Network_builder.send_transition ~logger ~transition_writer
              ~peer:large_peer
              (get_best_tip_hash large_peer)
          in
          let%bind run =
            f_with_verifier ~f:Bootstrap_controller.For_tests.run ~logger ~pids
              ~trust_system
          in
          let%map ( new_frontier
                  , (sorted_external_transitions :
                      External_transition.Initial_validated.t
                      Envelope.Incoming.t
                      list) ) =
            run ~network ~frontier:me ~ledger_db ~transition_reader
              ~should_ask_best_tip:false
          in
          heartbeat_flag := false ;
          assert_transitions_increasingly_sorted
            ~root:(Transition_frontier.root new_frontier)
            sorted_external_transitions ;
          Ledger_hash.equal (root_hash new_frontier)
            (root_hash large_peer.frontier) )

    let%test "`on_transition` should deny outdated transitions" =
      heartbeat_flag := true ;
      let pids = Child_processes.Termination.create_pid_table () in
      let num_breadcrumbs = 10 in
      Thread_safe.block_on_async_exn (fun () ->
          print_heartbeat hb_logger |> don't_wait_for ;
          let%bind syncing_frontier, peer_with_frontier, network =
            Network_builder.setup_me_and_a_peer ~logger ~pids ~trust_system
              ~num_breadcrumbs ~source_accounts:Test_genesis_ledger.accounts
              ~target_accounts:Test_genesis_ledger.accounts
          in
          let root_sync_ledger =
            Root_sync_ledger.create
              (Transition_frontier.For_tests.root_snarked_ledger
                 syncing_frontier)
              ~logger ~trust_system
          in
          let query_reader = Root_sync_ledger.query_reader root_sync_ledger in
          let response_writer =
            Root_sync_ledger.answer_writer root_sync_ledger
          in
          Network.glue_sync_ledger network query_reader response_writer ;
          let genesis_root =
            Transition_frontier.root syncing_frontier
            |> Transition_frontier.Breadcrumb.validated_transition
          in
          let open Bootstrap_controller.For_tests in
          let%bind make =
            f_with_verifier ~f:make_bootstrap ~logger ~pids ~trust_system
          in
          let bootstrap = make ~genesis_root ~network in
          let best_transition =
            Transition_frontier.best_tip peer_with_frontier.frontier
            |> Transition_frontier.Breadcrumb.validated_transition
            |> External_transition.Validation.forget_validation
          in
          let%bind should_sync =
            Bootstrap_controller.For_tests.on_transition bootstrap
              ~root_sync_ledger ~sender:peer_with_frontier.peer.host
              best_transition
          in
          assert (is_syncing should_sync) ;
          let outdated_transition =
            Transition_frontier.root peer_with_frontier.frontier
            |> Transition_frontier.Breadcrumb.validated_transition
            |> External_transition.Validation.forget_validation
          in
          let%map should_not_sync =
            Bootstrap_controller.For_tests.on_transition bootstrap
              ~root_sync_ledger ~sender:peer_with_frontier.peer.host
              outdated_transition
          in
          heartbeat_flag := false ;
          should_not_sync = `Ignored )
    *)
  end )
