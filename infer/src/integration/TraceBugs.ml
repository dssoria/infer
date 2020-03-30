(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module F = Format
module L = Logging

[@@@warning "+9"]

let is_past_limit limit =
  match limit with None -> fun _ -> false | Some limit -> fun n -> n >= limit


let has_trace {Jsonbug_t.bug_trace; _} = not (List.is_empty bug_trace)

let with_file_fmt file ~f =
  Utils.with_file_out file ~f:(fun outc ->
      let fmt = F.formatter_of_out_channel outc in
      f fmt ; F.pp_print_flush fmt () )


let pp_trace_item ~show_source_context fmt
    Jsonbug_t.{level; filename; line_number; column_number; description} =
  let pp_col_number fmt c = if c >= 0 then F.fprintf fmt ":%d" c in
  F.fprintf fmt "%s:%d%a: %s@\n" filename line_number pp_col_number column_number description ;
  if show_source_context then
    TextReport.pp_source_context ~indent:(2 * level) fmt
      {Jsonbug_t.file= filename; lnum= line_number; cnum= column_number; enum= -1}


let pp_issue_with_trace ~show_source_context ~max_nested_level fmt
    (n_issue, (issue : Jsonbug_t.jsonbug)) =
  F.fprintf fmt "#%d@\n%a@\n" n_issue TextReport.pp_jsonbug issue ;
  if List.is_empty issue.bug_trace then F.fprintf fmt "@\nEmpty trace@\n%!"
  else
    List.iter issue.bug_trace ~f:(fun trace_item ->
        (* subtract 1 to get inclusive limits on the nesting level *)
        if not (is_past_limit max_nested_level (trace_item.Jsonbug_t.level - 1)) then
          F.fprintf fmt "@\n%a" (pp_trace_item ~show_source_context) trace_item )


let user_select_issue ~selector_limit report =
  List.fold_until report
    ~finish:(fun _ -> ())
    ~init:0
    ~f:(fun n issue ->
      if is_past_limit selector_limit n then Stop ()
      else (
        L.result "#%d@\n%a@\n" n TextReport.pp_jsonbug issue ;
        Continue (n + 1) ) ) ;
  let rec ask_until_valid_input max_report =
    L.result "@\nSelect report to display (0-%d) (default: 0): %!" max_report ;
    let input = In_channel.input_line_exn In_channel.stdin in
    if String.is_empty input then 0
    else
      match int_of_string_opt input with
      | Some n when n >= 0 && n <= max_report ->
          n
      | Some n ->
          L.progress "Error: %d is not between 0 and %d, try again.@\n%!" n max_report ;
          ask_until_valid_input max_report
      | None ->
          L.progress "Error: please input a number, not '%s'.@\n%!" input ;
          ask_until_valid_input max_report
  in
  let n = ask_until_valid_input (List.length report - 1) in
  (n, List.nth_exn report n)


let read_report report_json = Atdgen_runtime.Util.Json.from_file Jsonbug_j.read_report report_json

let explore ~selector_limit ~report_txt:_ ~report_json ~show_source_context ~selected
    ~max_nested_level =
  let report = read_report report_json in
  let issue_to_display =
    match (selected, report) with
    | Some n, _ -> (
      (* an issue number has been pre-selected, use that *)
      match List.nth report n with
      | None ->
          L.die UserError "Cannot select issues #%d: only %d issues in '%s'" n (List.length report)
            report_json
      | Some issue ->
          Some (n, issue) )
    | None, [] ->
        (* empty report, can't print anything *)
        L.progress "No issues found in '%s', exiting.@\n" report_json ;
        None
    | None, [issue] ->
        (* single-issue report: no need to prompt the user to select which issue to display *)
        L.progress "Auto-selecting the only issue in '%s'@\n%!" report_json ;
        Some (0, issue)
    | None, _ :: _ :: _ ->
        (* user prompt *)
        Some (user_select_issue ~selector_limit report)
  in
  Option.iter issue_to_display ~f:(fun issue ->
      L.result "@\n%a" (pp_issue_with_trace ~show_source_context ~max_nested_level) issue )


let trace_path_of_bug_number ~traces_dir i = traces_dir ^/ Printf.sprintf "bug_%d.txt" i

let pp_html_index ~traces_dir fmt report =
  let pp_issue_entry fmt issue_i =
    let pp_trace_uri fmt (i, (issue : Jsonbug_t.jsonbug)) =
      if has_trace issue then
        F.fprintf fmt "<a href=\"%s\">trace</a>" (trace_path_of_bug_number ~traces_dir i)
      else F.pp_print_string fmt "no trace"
    in
    F.fprintf fmt "<li>%a (%a)</li>" TextReport.pp_jsonbug (snd issue_i) pp_trace_uri issue_i
  in
  let pp_issues_list fmt report =
    F.fprintf fmt "<ol start=\"0\">@\n" ;
    List.iteri report ~f:(fun i issue -> pp_issue_entry fmt (i, issue)) ;
    F.fprintf fmt "@\n</ol>"
  in
  F.fprintf fmt
    {|<html>
<head>
<title>Infer found %d issues</title>
</head>
<body>
<h2>List of issues found</h2>
%a
</body>
</html>|}
    (List.length report) pp_issues_list report


let gen_html_report ~show_source_context ~max_nested_level ~report_json ~report_html_dir =
  (* delete previous report if present *)
  Utils.rmtree report_html_dir ;
  Utils.create_dir report_html_dir ;
  let traces_dir = "traces" in
  Utils.create_dir (report_html_dir ^/ traces_dir) ;
  let report = read_report report_json in
  List.iteri report ~f:(fun i issue ->
      if has_trace issue then
        let file = report_html_dir ^/ trace_path_of_bug_number ~traces_dir i in
        with_file_fmt file ~f:(fun fmt ->
            pp_issue_with_trace ~show_source_context ~max_nested_level fmt (i, issue) ) ) ;
  let report_html = report_html_dir ^/ "index.html" in
  with_file_fmt report_html ~f:(fun fmt -> pp_html_index ~traces_dir fmt report) ;
  L.result "Saved HTML report in '%s'@." report_html