## Personal Time Keeper
## ====================
##
## Simple time keeping CLI

import algorithm, docopt, json, langutils, logging, os, nre, sequtils,
  sets, strutils, tempfile, terminal, times, timeutils, uuids

import private/util
import private/api
import private/models

#proc `$`*(mark: Mark): string =
  #return (($mark.uuid)[

proc exitErr(msg: string): void =
  fatal "ptk: " & msg
  quit(QuitFailure)

proc flexFormat(i: TimeInterval): string =
  ## Pretty-format a time interval.

  let fmt =
    if i > 1.days: "d'd' H'h' m'm'"
    elif i >= 1.hours: "H'h' m'm'"
    elif i >= 1.minutes: "m'm' s's'"
    else: "s's'"

  return i.format(fmt)

type WriteData = tuple[idx: int, mark: Mark, prefixLen: int, interval: TimeInterval]

proc writeMarks(timeline: Timeline, indices: seq[int], includeNotes = false): void =
  ## Write a nicely-formatted list of Marks to stdout.

  let marks = timeline.marks
  let now = getTime().local

  if indices.len == 0:
    writeLine(stdout, "No marks match the given criteria.")
    return

  var idxs = indices.sorted(
    proc(a, b: int): int = cmp(marks[a].time, marks[b].time))

  let largestInterval = now - marks[idxs.first].time
  let timeFormat =
    if largestInterval > 1.years: "yyyy-MM-dd HH:mm"
    elif largestInterval > 7.days: "MMM dd HH:mm"
    elif largestInterval > 1.days: "ddd HH:mm"
    else: "HH:mm"

  var toWrite: seq[WriteData] = @[]

  var longestPrefix = 0

  for i in idxs:
    let
      interval: TimeInterval =
        if (i == marks.len - 1): now - marks[i].time
        else: marks[i + 1].time - marks[i].time
      prefix =
        ($marks[i].id)[0..<8] & "  " & marks[i].time.format(timeFormat) &
        " (" & interval.flexFormat & ")"

    toWrite.add((
      idx: i,
      mark: marks[i],
      prefixLen: prefix.len,
      interval: interval))

    if prefix.len > longestPrefix: longestPrefix = prefix.len

  let colWidth = 80
  let notesPrefixLen = 4

  for w in toWrite:
    if w.mark.summary == STOP_MSG: continue

    setForegroundColor(stdout, fgBlack, true)
    write(stdout, ($w.mark.id)[0..<8])
    setForegroundColor(stdout, fgYellow)
    write(stdout, "  " & w.mark.time.format(timeFormat))
    setForegroundColor(stdout, fgCyan)
    write(stdout, " (" & w.interval.flexFormat & ")")
    resetAttributes(stdout)
    write(stdout, spaces(longestPrefix - w.prefixLen) & " -- " & w.mark.summary)

    if w.mark.tags.len > 0:
      setForegroundColor(stdout, fgGreen)
      write(stdout, " (" & w.mark.tags.join(", ") & ")")
      resetAttributes(stdout)

    writeLine(stdout, "")

    if includeNotes and len(w.mark.notes.strip) > 0:
      writeLine(stdout, "")
      let wrappedNotes = wordWrap(s = w.mark.notes,
                                  maxLineWidth = colWidth)
      for line in splitLines(wrappedNotes):
        writeLine(stdout, spaces(notesPrefixLen) & line)
      writeLine(stdout, "")

proc doInit(timelineLocation: string): void =
  ## Interactively initialize a new timeline at the given file path.

  stdout.write "Time log name [New Timeline]: "
  let name = stdin.readLine()

  let timeline = %*
    { "name": if name.strip.len > 0: name.strip else: "New Timeline",
      "marks": [] }
      #"createdAt": getLocalTime().format("yyyy-MM-dd'T'HH:mm:ss") }

  var timelineFile: File
  try:
    timelineFile = open(timelineLocation, fmWrite)
    timelineFile.write($timeline.pretty)
  finally: close(timelineFile)

type ExpectedMarkPart = enum Time, Summary, Tags, Notes

proc edit(mark: var Mark): void =
  ## Interactively edit a mark using the editor named in the environment
  ## variable "EDITOR"

  var
    tempFile: File
    tempFileName: string

  try:
    (tempFile, tempFileName) = mkstemp("timestamp-mark-", ".txt", "", fmWrite)
    tempFile.writeLine(
      """# Edit the time, mark, tags, and notes below. Any lines starting with '#' will
# be ignored. When done, save the file and close the editor.""")
    tempFile.writeLine(mark.time.format(ISO_TIME_FORMAT))
    tempFile.writeLine(mark.summary)
    tempFile.writeLine(mark.tags.join(","))
    tempFile.writeLine(
      """# Everything from the line below to the end of the file will be considered
# notes for this timeline mark.""")

    close(tempFile)

    discard os.execShellCmd "$EDITOR " & tempFileName & " </dev/tty >/dev/tty"

    var markPart = Time

    for line in lines tempFileName:
      if strip(line)[0] == '#': continue
      elif markPart == Time: mark.time = parseTime(line); markPart = Summary
      elif markPart == Summary: mark.summary = line; markPart = Tags
      elif markPart == Tags:
        mark.tags = line.split({',', ';'});
        markPart = Notes
      else: mark.notes &= line & "\x0D\x0A"

  finally: close(tempFile)

proc filterMarkIndices(timeline: Timeline, args: Table[string, Value]): seq[int] =
  ## Filter down a set of marks according to options provided in command line
  ## arguments.

  let marks = timeline.marks
  let now = getTime().local
  let allIndices = sequtils.toSeq(0..<marks.len).filterIt(marks[it].summary != STOP_MSG).toSet
  let union = args["--or"]

  var selected =
    if union: initSet[int]()
    else: allIndices

  template filterMarks(curSet: HashSet[int], pred: untyped): untyped =
    var res: HashSet[int] = initSet[int]()
    if union:
      for mIdx {.inject.} in allIndices:
        if pred: res.incl(mIdx)
      res = res + curSet
    else:
      for mIdx {.inject.} in curSet:
        if pred: res.incl(mIdx)
    res

  if args["<firstId>"]:
    let idx = marks.findById($args["<firstId>"])
    if idx > 0: selected = selected.filterMarks(mIdx >= idx)

  if args["<lastId>"]:
    let idx = marks.findById($args["<lastId>"])
    if (idx > 0): selected = selected.filterMarks(mIdx <= idx)

  if args["--after"]:
    var startTime: DateTime
    try: startTime = parseTime($args["--after"])
    except: raise newException(ValueError,
      "invalid value for --after: " & getCurrentExceptionMsg())
    selected = selected.filterMarks(marks[mIdx].time > startTime)

  if args["--before"]:
    var endTime: DateTime
    try: endTime = parseTime($args["--before"])
    except: raise newException(ValueError,
      "invalid value for --before: " & getCurrentExceptionMsg())
    selected = selected.filterMarks(marks[mIdx].time < endTime)

  if args["--today"]:
    let b = now.startOfDay
    let e = b + 1.days
    selected = selected.filterMarks(marks[mIdx].time >= b and marks[mIdx].time < e)

  if args["--yesterday"]:
    let e = now.startOfDay
    let b = e - 1.days
    selected = selected.filterMarks(marks[mIdx].time >= b and marks[mIdx].time < e)

  if args["--this-week"]:
    let b = now.startOfWeek(dSun)
    let e = b + 7.days
    selected = selected.filterMarks(marks[mIdx].time >= b and marks[mIdx].time < e)

  if args["--last-week"]:
    let e = now.startOfWeek(dSun)
    let b = e - 7.days
    selected = selected.filterMarks(marks[mIdx].time >= b and marks[mIdx].time < e)

  if args["--tags"]:
    let tags = (args["--tags"] ?: "").split({',', ';'})
    selected = selected.filterMarks(tags.allIt(marks[mIdx].tags.contains(it)))

  if args["--remove-tags"]:
    let tags = (args["--remove-tags"] ?: "").split({',', ';'})
    selected = selected.filterMarks(not tags.allIt(marks[mIdx].tags.contains(it)))

  if args["--matching"]:
    let pattern = re("(?i)" & $(args["--matching"] ?: ""))
    selected = selected.filterMarks(marks[mIdx].summary.find(pattern).isSome)

  return sequtils.toSeq(selected.items).sorted(system.cmp)

when isMainModule:
 try:
  let doc = """
Usage:
  ptk init [options]
  ptk (add | start) [options]
  ptk (add | start) [options] <summary>
  ptk resume [options] [<id>]
  ptk amend [options] [<id>] [<summary>]
  ptk merge <timeline> [<timeline>...]
  ptk stop [options]
  ptk continue
  ptk delete <id>
  ptk (list | ls) [options]
  ptk (list | ls) tags
  ptk current
  ptk sum-time --ids <ids>...
  ptk sum-time [options] [<firstId>] [<lastId>]
  ptk (-V | --version)
  ptk (-h | --help)

Options:

  -E --echo-args          Echo the program's understanding of it's arguments.
  -V --version            Print the tool's version information.
  -a --after <after>      Restrict the selection to marks after <after>.
  -b --before <before>    Restrict the selection to marks after <before>.
  -c --config <cfgFile>   Use <cfgFile> as configuration for the CLI.
  -e --edit               Open the mark in an editor.
  -f --file <file>        Use the given timeline file.
  -g --tags <tags>        Add the given tags (comma-separated) to the selected marks.
  -G --remove-tags <tagx> Remove the given tag from the selected marks.
  -h --help               Print this usage information.
  -m --matching <pattern> Restric the selection to marks matching <pattern>.
  -n --notes <notes>      For add and amend, set the notes for a time mark.
  -t --time <time>        For add and amend, use this time instead of the current time.
  -T --today              Restrict the selection to marks during today.
  -Y --yesterday          Restrict the selection to marks during yesterday.
  -w --this-week          Restrict the selection to marks during this week.
  -W --last-week          Restrict the selection to marks during the last week.
  -O --or                 Create a union from the time conditionals, not an intersection
                          (e.g. --today --or --yesterday)
  -v --verbose            Include notes in timeline entry output.
"""


  logging.addHandler(newConsoleLogger())
  let now = getTime().local

  # Parse arguments
  let args = docopt(doc, version = "ptk 0.12.4")

  if args["--echo-args"]: echo $args

  if args["--help"]:
    echo doc
    quit()

  # Find and parse the .ptkrc file
  let ptkrcLocations = @[
    if args["--config"]: $args["--config"] else:"",
    ".ptkrc", $getEnv("PTKRC"), $getEnv("HOME") & "/.ptkrc"]

  var ptkrcFilename: string =
    foldl(ptkrcLocations, if len(a) > 0: a elif existsFile(b): b else: "")

  var cfg: JsonNode
  var cfgFile: File
  if not existsFile(ptkrcFilename):
    warn "ptk: could not find .ptkrc file."
    ptkrcFilename = $getEnv("HOME") & "/.ptkrc"
    try:
      cfgFile = open(ptkrcFilename, fmWrite)
      cfgFile.write("{\"timelineLogFile\": \"timeline.log.json\"}")
    except: warn "ptk: could not write default .ptkrc to " & ptkrcFilename
    finally: close(cfgFile)

  try: cfg = parseFile(ptkrcFilename)
  except: raise newException(IOError,
    "unable to read config file: " & ptkrcFilename &
    "\x0D\x0A" & getCurrentExceptionMsg())

  # Find the time log file
  let timelineLocations = @[
    if args["--file"]: $args["--file"] else: "",
    $getEnv("PTK_FILE"),
    cfg["timelineLogFile"].getStr(""),
    "ptk.log.json"]

  var timelineLocation =
    foldl(timelineLocations, if len(a) > 0: a elif existsFile(b): b else: "")

  # Execute commands
  if args["init"]:
    doInit(foldl(timelineLocations, if len(a) > 0: a else: b))

  elif args["merge"]:

    let filesToMerge = args["<timeline>"]
    let timelines = filesToMerge.mapIt(loadTimeline(it))

    let names = timelines.mapIt(it.name).toSet
    let mergedName = sequtils.toSeq(names.items).foldl(a & " + " & b)
    var merged: Timeline = (
      name: mergedName,
      marks: @[])

    for timeline in timelines:
      for mark in timeline.marks:
        var existingMarkIdx = merged.marks.findById($mark.id)
        if existingMarkIdx >= 0:
          if merged.marks[existingMarkIdx].summary != mark.summary:
            merged.marks[existingMarkIdx].summary &= " | " & mark.summary
          if merged.marks[existingMarkIdx].notes != mark.notes:
            merged.marks[existingMarkIdx].notes &= "\r\n--------\r\b" & mark.notes

        else: merged.marks.add(mark)

    writeLine(stdout, pretty(%merged))

  else:

    if not fileExists(timelineLocation):
      raise newException(IOError,
        "time log file doesn't exist: " & timelineLocation)

    var timeline = loadTimeline(timelineLocation)

    if args["stop"]:

      if timeline.marks.last.summary == STOP_MSG:
        echo "ptk: no current task, nothing to stop"
        quit(0)

      let newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: STOP_MSG,
        notes: args["--notes"] ?: "",
        tags: (args["--tags"] ?: "").split({',', ';'}).filterIt(not it.isNilOrWhitespace))
        
      timeline.marks.add(newMark)

      timeline.writeMarks(
        indices = @[timeline.marks.len - 2],
        includeNotes = args["--verbose"])
      echo "ptk: stopped timer"

      saveTimeline(timeline, timelineLocation)

    if args["continue"]:

      if timeline.marks.last.summary != STOP_MSG:
        echo "ptk: there is already something in progress:"
        timeline.writeMarks(
          indices = @[timeline.marks.len - 1],
          includeNotes = args["--verbose"])
        quit(0)

      let prevMark = timeline.marks[timeline.marks.len - 2]
      var newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: prevMark.summary,
        notes: prevMark.notes,
        tags: prevMark.tags)

      timeline.marks.add(newMark)
      timeline.writeMarks(
        indices = @[timeline.marks.len - 1],
        includeNotes = args["--verbose"])

      saveTimeline(timeline, timelineLocation)

    if args["add"] or args["start"]:

      var newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: args["<summary>"] ?: "",
        notes: args["--notes"] ?: "",
        tags: (args["--tags"] ?: "").split({',', ';'}).filterIt(not it.isNilOrWhitespace))

      if args["--edit"]: edit(newMark)

      let prevLastIdx = timeline.marks.getLastIndex()
      timeline.marks.add(newMark)
      timeline.writeMarks(
        indices = if prevLastIdx < 0: @[0]
                  else: @[prevLastIdx, timeline.marks.len - 1],
        includeNotes = args["--verbose"])

      saveTimeline(timeline, timelineLocation)

    if args["resume"]:

      var markToResumeIdx: int

      if args["<id>"]:
        markToResumeIdx = timeline.marks.findById($args["<id>"])
        if markToResumeIdx == -1: exitErr "Cannot find a mark matching " & $args["<id>"]
      else:
        markToResumeIdx = timeline.marks.getLastIndex()
        if markToResumeIdx < 0: exitErr "No mark to resume."
      var markToResume = timeline.marks[markToResumeIdx]
      
      var newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: markToResume.summary,
        notes: markToResume.notes,
        tags: markToResume.tags)

      if args["--edit"]: edit(newMark)

      timeline.marks.add(newMark)
      timeline.writeMarks(
        indices = sequtils.toSeq(markToResumeIdx..<timeline.marks.len),
        includeNotes = args["--verbose"])
        
      saveTimeline(timeline, timelineLocation)

    if args["amend"]:

      # Note, this returns a copy, not a reference to the mark in the seq.
      var markIdx: int

      if args["<id>"]:
        markIdx = timeline.marks.findById($args["<id>"])
        if markIdx == -1: exitErr "Cannot find a mark matching " & $args["<id>"]
      else:
        markIdx = timeline.marks.getLastIndex()
        if markIdx < 0: exitErr "No mark to amend."

      var mark = timeline.marks[markIdx]
      
      if args["<summary>"]: mark.summary = $args["<summary>"]
      if args["--notes"]: mark.notes = $args["<notes>"]
      if args["--tags"]:
        mark.tags &= (args["--tags"] ?: "").split({',', ';'})
        mark.tags = mark.tags.deduplicate
      if args["--remove-tags"]:
        let tagsToRemove = (args["--remove-tags"] ?: "").split({',', ';'})
        mark.tags = mark.tags.filter(proc (t: string): bool =
          anyIt(tagsToRemove, it == t))
      if args["--time"]:
        try: mark.time = parseTime($args["--time"])
        except: raise newException(ValueError,
          "invalid value for --time: " & getCurrentExceptionMsg())

      if args["--edit"]: edit(mark)

      timeline.marks.delete(markIdx)
      timeline.marks.insert(mark, markIdx)

      timeline.writeMarks(
        indices = @[markIdx],
        includeNotes = args["--verbose"])


      saveTimeline(timeline, timelineLocation)

    if args["delete"]:

      let markIdx = timeline.marks.findById($args["<id>"])
      timeline.marks.delete(markIdx)
      saveTimeline(timeline, timelineLocation)

    if args["list"] or args["ls"]:

      if args["tags"]:

        echo $(timeline.marks.mapIt(it.tags)
                .flatten().deduplicate().sorted(system.cmp).join("\n"))

      else:
        var selectedIndices = timeline.filterMarkIndices(args)

        timeline.writeMarks(
          indices = selectedIndices,
          includeNotes = args["--verbose"])

    if args["current"]:

      let idx = timeline.marks.len - 1
      if timeline.marks[idx].summary == STOP_MSG:
        echo "ptk: no current task"
      else:
        timeline.writeMarks(
          indices = @[idx],
          includeNotes = true)

    if args["sum-time"]:
    
      var intervals: seq[TimeInterval] = @[]

      if args["--ids"]:
        for id in args["<ids>"]:
          let markIdx = timeline.marks.findById(id)
          if markIdx == -1:
            warn "ptk: could not find mark for id " & id
          elif markIdx == timeline.marks.len - 1:
            intervals.add(now - timeline.marks.last.time)
          else:
            intervals.add(timeline.marks[markIdx + 1].time - timeline.marks[markIdx].time)

      else:

        var indicesToSum = timeline.filterMarkIndices(args)

        for idx in indicesToSum:
          let mark = timeline.marks[idx]
          if idx == timeline.marks.len - 1: intervals.add(now - mark.time)
          else: intervals.add(timeline.marks[idx + 1].time - mark.time)

      if intervals.len == 0:
        echo "ptk: no marks found"

      else:
        let total = intervals.foldl(a + b)
        echo flexFormat(total)
 
 except:
  fatal "ptk: " & getCurrentExceptionMsg()
  quit(QuitFailure)
