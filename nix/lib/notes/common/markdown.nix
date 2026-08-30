{ lib }:

# Provider-agnostic markdown builders. Used by templates/proxmox/ and
# (eventually) templates/xen-orchestra/. PVE renders Notes via marked.js
# and XO renders name_description via showdown — both accept the
# CommonMark subset emitted here.

rec {
  heading = level: text:
    let
      hashes =
        if level == 1 then "#"
        else if level == 2 then "##"
        else if level == 3 then "###"
        else throw "markdown.heading: only levels 1-3 supported (got ${toString level})";
    in "${hashes} ${text}";

  link = { text, url }: "[${text}](${url})";

  bulletList = items: lib.concatMapStringsSep "\n" (s: "- ${s}") items;

  # Markdown table. headers :: [str], rows :: [[str]].
  table = { headers, rows }:
    let
      headerLine = "| ${lib.concatStringsSep " | " headers} |";
      separator  = "|${lib.concatStringsSep "|" (map (_: "---") headers)}|";
      rowLines   = map (cells: "| ${lib.concatStringsSep " | " cells} |") rows;
    in lib.concatStringsSep "\n" ([ headerLine separator ] ++ rowLines);

  # Renders heading + body only when body is non-empty. Returns "" if
  # the section has nothing to show.
  section = { level ? 2, title, body }:
    if body == "" then ""
    else "${heading level title}\n\n${body}";

  # Joins parts with blank-line separators, dropping empties so the
  # output never has stray double-blanks.
  join = parts: lib.concatStringsSep "\n\n" (lib.filter (s: s != "") parts);
}
