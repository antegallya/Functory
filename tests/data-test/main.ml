
open Functory.Network
let () = declare_workers ~n:6 "localhost"
let () = declare_workers ~n:6 "belzebuth"
open Same

let t = 80

let checksum a =
  let r = ref "" in
  for i = 0 to Array.length a - 1 do
    r := Digest.string a.(i) ^ !r
  done

let input = Array.init t (fun _ -> String.create 8_000_000)

let tasks = 
  let l = ref [] in
  Array.iteri (fun i si -> l := (si, i)  :: !l) input;
  !l

let output = Array.create t ""

let () =
  let worker s = Unix.sleep 2; s in
  let master (s, i) r = output.(i) <- s; [] in
  compute ~worker ~master tasks

let () = assert (checksum output = checksum input)
let () = Format.printf "success!@."

(*
Local Variables: 
compile-command: "make -C ../.. install-data-test"
End: 
*)
