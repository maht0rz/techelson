(* CLAP stuff. *)

open Format

module Arg = struct
    (* Arguments: short (flag) or long. *)
    type t =
    (* Flag: `-v`. *)
    | Short of char
    (* Option: `--verb`. *)
    | Long of string
    (* Value: some string. *)
    | Val of string

    (* Returns the head if it is a value, none otherwise. *)
    let next_value (l : t list) : (string * t list) option = match l with
    | (Val v) :: tail -> Some (v, tail)
    | _ -> None

    (* Same as `next_value` but converts the value to an `int`. *)
    let next_int (l : t list) : (int * t list) option = match next_value l with
    | Some (v, tail) ->
        Exc.erase_err
            (fun () -> sprintf "expected integer value, found `%s`" v)
            (fun () -> Some ((int_of_string v), tail))
    | None -> None
end


module Cla = struct
    type t = {
        short : char list;
        long : string list;
        action : Arg.t list -> Conf.t -> Arg.t list;
    }
    let mk
        (short : char list)
        (long : string list)
        (action : Arg.t list -> Conf.t -> Arg.t list)
        : t
    = { short ; long ; action }

    let verb : t =
        mk ['v'] ["verb"] (
            fun args conf -> match Arg.next_int args with
            | None ->
                conf.verb <- conf.verb + 1;
                args
            | Some (i, tail) ->
                conf.verb <- i;
                tail
        )

    let options : t list = [ verb ]

    let add_all
        (long_map : (string, Arg.t list -> Conf.t -> Arg.t list) Hashtbl.t)
        (short_map : (char, Arg.t list -> Conf.t -> Arg.t list) Hashtbl.t)
    = options |> List.iter (
        fun { short ; long ; action } ->
            short |> List.iter (
                fun (c : char) -> Hashtbl.add short_map c action
            );
            long |> List.iter (
                fun (s : string) -> Hashtbl.add long_map s action
            );
    )
end



(* Command line arguments. *)
let args : string list =
    (Array.length Sys.argv) - 1 |> Array.sub Sys.argv 1 |> Array.to_list

(* Map from long options to option handler. *)
let long_map : (string, Arg.t list -> Conf.t -> Arg.t list) Hashtbl.t =
    Hashtbl.create ~random:false 101
(* Map from short options to option handler. *)
let short_map : (char, Arg.t list -> Conf.t -> Arg.t list) Hashtbl.t =
    Hashtbl.create ~random:false 101

let _ = Cla.add_all long_map short_map

(* Preprocesses arguments to split arguments.

    Splits aggregated flags `-vvvafg` in `(short v) :: (short v) :: ...`. *)
let split_args (args : string list) : Arg.t list =
    (* Splits flags. The string must not have the `-` prefix for flags. *)
    let split_flags (acc : Arg.t list) (s : string) : Arg.t list =
        let rec loop (acc : Arg.t list) (cursor : int) (s : string) =
            if cursor >= String.length s then (
                acc
            ) else (
                let acc = (Arg.Short (String.get s cursor)) :: acc in
                loop acc (cursor + 1) s
            )
        in
        loop acc 0 s
    in
    (* Actual short/long splitting. *)
    let rec loop (acc : Arg.t list) : string list -> Arg.t list = function
        | [] -> List.rev acc
        (* Separator, everything else is a value. *)
        | "--" :: tail -> tail |> List.map (fun s -> Arg.Val s) |> List.rev_append acc
        | head :: tail -> (
            let acc =
                if String.length head > 1
                && String.get head 0 = '-'
                && String.get head 1 = '-' then (
                    let offset = 2 in
                    let (start, finsh) = (offset, (String.length head - offset)) in
                    (Arg.Long (String.sub head start finsh)) :: acc
                ) else if String.length head > 0 && String.get head 0 = '-' then (
                    let offset = 1 in
                    let (start, finsh) = (offset, (String.length head - offset)) in
                    String.sub head start finsh |> split_flags acc
                ) else (
                    (Arg.Val head) :: acc
                )
            in
            loop acc tail
        )
    in
    loop [] args



(* Handles a list of arguments. *)
let handle_args (conf : Conf.t) (args : Arg.t list) : Conf.t =
    let rec loop (args : Arg.t list) : Conf.t = match args with
    | [] -> (
        conf.args <- List.rev conf.args;
        conf
    )
    (* Value that was not eaten by an option. Add to configuration's args. *)
    | (Arg.Val s) :: tail -> (
        conf.args <- s :: conf.args;
        loop tail
    )
    (* Flag, does not take arguments. *)
    | (Arg.Short c) :: tail -> (match Hashtbl.find_opt short_map c with
        | Some action ->
            (* Notice the empty list of arguments (first argument). *)
            action [] conf |> ignore;
            loop tail
        | None -> sprintf "unknown flag `-%c`" c |> Exc.throw
    )
    (* Option, expected to take arguments. *)
    | (Arg.Long s) :: tail -> (match Hashtbl.find_opt long_map s with
        | Some action ->
            (* Feed tail arguments, get new tail back. *)
            let tail = action tail conf in
            loop tail
        | None -> sprintf "unknown option `--%s`" s |> Exc.throw
    )
    in
    loop args



(* Runs CLAP on custom arguments. *)
let run_on (args : string list) : Conf.t =
    args |> split_args |> handle_args Conf.default

(* Runs CLAP on CLAs. *)
let run () : Conf.t = run_on args

(* Sets the configuration in `Common`. *)
let set_conf () : unit =
    let chained : unit -> Conf.t =
        fun () -> Exc.chain_err (
            fun () -> "while parsing command-line arguments"
        ) (fun () -> Clap.run ())
    in
    Exc.catch_fail chained |> Base.Common.set_conf