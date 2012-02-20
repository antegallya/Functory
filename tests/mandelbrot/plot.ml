
let l =
  [10, 9.478;
   20, 8.153;
   30, 8.272;
   40, 8.242;
   50, 8.299;
   60, 8.279;
   70, 8.275;
   80, 8.354;
   90, 8.307;
   100, 8.375;
  200, 8.594;
  300, 8.845;
  400, 9.052;
  ]

let print (t, timing) =
  let s = float 6000 /. float t +. 1. in
  Format.printf "%f %f@." s (timing /. float t)

let () = List.iter print (List.rev l)


