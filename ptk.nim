## Personal Time Keeper
## ====================
##
## Simple time keeping CLI

import algorithm, docopt, json, langutils, logging, os, nre, sequtils,
  sets, strutils, tempfile, terminal, times, timeutils, uuids

import private/ptkutil

type
  Mark* = tuple[id: UUID, time: TimeInfo, summary: string, notes: string, tags: seq[string]]
    ## Representation of a single mark on the timeline.

  Timeline* = tuple[name: string, marks: seq[Mark]]
    ## Representation of a timeline: a name and sequence of Marks.

const STOP_MSG = "STOP"

let NO_MARK: Mark = (
  id: parseUUID("00000000-0000-0000-0000-000000000000"),
  time: fromSeconds(0).getLocalTime,
  summary: "", notes: "", tags: @[])

const ISO_TIME_FORMAT = "yyyy-MM-dd'T'HH:mm:ss"
  ## The canonical time format used by PTK.

const TIME_FORMATS = @[
    "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm",
    "MM-dd'T'HH:mm:ss", "MM-dd HH:mm:ss",
    "MM-dd'T'HH:mm", "MM-dd HH:mm",
    "HH:mm:ss", "H:mm:ss", "H:mm", "HH:mm" ]
  ## Other time formats that PTK will accept as input.

#proc `$`*(mark: Mark): string =
  #return (($mark.uuid)[

proc exitErr(msg: string): void =
  fatal "ptk: " & msg
  quit(QuitFailure)

proc parseTime(timeStr: string): TimeInfo =
  ## Helper to parse time strings trying multiple known formats. 
  for fmt in TIME_FORMATS:
    try: return parse(timeStr, fmt)
    except: discard nil

  raise newException(Exception, "unable to interpret as a date: " & timeStr)

template `%`(mark: Mark): JsonNode =
  %* {
    "id": $(mark.id),
    "time": mark.time.format(ISO_TIME_FORMAT),
    "summary": mark.summary,
    "notes": mark.notes,
    "tags": mark.tags
  }

template `%`(timeline: Timeline): JsonNode =
  %* { "name": timeline.name, "marks": timeline.marks }

proc loadTimeline(filename: string): Timeline =
  ## Load a timeline from a file. Expects a path to a file (can be relative or
  ## absolute) and returns a Timeline. The marks in the timeline are guaranteed
  ## to be ordered by time.

  var timelineJson: JsonNode
  try: timelineJson = parseFile(filename)
  except:
    raise newException(ValueError,
      "unable to parse the timeline file as JSON: " & filename)

  var timeline: Timeline = (name: timelineJson["name"].getStr(), marks: @[])

  for markJson in timelineJson["marks"]:

    # TODO: an incorrect time format that was used in version 0.6 and prior.
    # Version 0.7 between 1.0 support this format on read only and will write
    # out the correct  format (so they can be used to convert older timelines).
    var time: TimeInfo
    try: time = parse(markJson["time"].getStr(), ISO_TIME_FORMAT)
    except: time = parse(markJson["time"].getStr(), "yyyy:MM:dd'T'HH:mm:ss")

    timeline.marks.add((
      id: parseUUID(markJson["id"].getStr()),
      time: time, #parse(markJson["time"].getStr(), ISO_TIME_FORMAT),
      summary: markJson["summary"].getStr(),
      notes: markJson["notes"].getStr(),
      tags: markJson["tags"].getElems(@[]).map(proc (t: JsonNode): string = t.getStr())))

  timeline.marks = timeline.marks.sorted(
    proc(a, b: Mark): int = cmp(a.time, b.time))

  return timeline

proc saveTimeline(timeline: Timeline, location: string): void =
  ## Write the timeline to disk at the file location given.

  var timelineFile: File
  try:
    timelineFile = open(location, fmWrite)
    timelineFile.writeLine(pretty(%timeline))
  except: raise newException(IOError, "unable to save changes to " & location)
  finally: close(timelineFile)

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
  let now = getLocalTime(getTime())

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
      writeLine(stdout, spaces(longestPrefix) & w.mark.notes)
      writeLine(stdout, "")

proc formatMark(mark: Mark, nextMark = NO_MARK, timeFormat = ISO_TIME_FORMAT, includeNotes = false): string =
  ## Pretty-format a Mark, optionally taking the next Mark in the timeline (to
  ## compute duration) and a time format string, and conditionally including
  ## the Mark's notes in the output.

  let nextTime =
    if nextMark == NO_MARK: getLocalTime(getTime())
    else: nextMark.time

  let duration = (nextTime - mark.time).flexFormat
  # TODO: pick up here calculating the time between marks

  let prefix = ($mark.id)[0..<8] & "  " & mark.time.format(timeFormat) & " (" & duration & ") -- "
  let prefixLen = len(($mark.id)[0..<8] & "  " & mark.time.format(timeFormat) & " (" & duration & ") -- ")

  result = prefix & mark.summary
  if includeNotes and len(mark.notes.strip()) > 0:
    let wrappedNotes = wordWrap(s = mark.notes, maxLineWidth = 80 - prefixLen)
    for line in splitLines(wrappedNotes):
      result &= "\x0D\x0A" & spaces(prefixLen) & line
    result &= "\x0D\x0A"

proc findById(marks: seq[Mark], id: string): int =
  var idx = 0
  for mark in marks:
    if startsWith($mark.id, id): return idx
    inc(idx)

  return -1

proc getLastIndex(marks: seq[Mark]): int =
  ## Find and return the index of the last Mark that was not a STOP mark.
  ## Returns -1 if there is no such last mark.

  var idx = marks.len - 1
  while idx >= 0 and marks[idx].summary == STOP_MSG: idx -= 1
  if idx < 0: result = -1
  else: result = idx

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
  result = sequtils.toSeq(0..<marks.len).filterIt(marks[it].summary != STOP_MSG)

  if args["<firstId>"]:
    let idx = marks.findById($args["<firstId>"])
    if idx > 0: result = result.filterIt(it >= idx)

  if args["<lastId>"]:
    let idx = marks.findById($args["<lastId>"])
    if (idx > 0): result = result.filterIt(it <= idx)

  if args["--after"]:
    var startTime: TimeInfo
    try: startTime = parseTime($args["--after"])
    except: raise newException(ValueError,
      "invalid value for --after: " & getCurrentExceptionMsg())
    result = result.filterIt(marks[it].time > startTime)

  if args["--before"]:
    var endTime: TimeInfo
    try: endTime = parseTime($args["--before"])
    except: raise newException(ValueError,
      "invalid value for --before: " & getCurrentExceptionMsg())
    result = result.filterIt(marks[it].time < endTime)

  if args["--today"]:
    let now = getLocalTime(getTime())
    let b = now.startOfDay
    let e = b + 1.days
    result = result.filterIt(marks[it].time >= b and marks[it].time < e)

  if args["--this-week"]:
    let now = getLocalTime(getTime())
    let b = now.startOfWeek(dSun)
    let e = b + 7.days
    result = result.filterIt(marks[it].time >= b and marks[it].time < e)

  if args["--last-week"]:
    let now = getLocalTime(getTime())
    let e = now.startOfWeek(dSun)
    let b = e - 7.days
    result = result.filterIt(marks[it].time >= b and marks[it].time < e)

  if args["--tags"]:
    let tags = (args["--tags"] ?: "").split({',', ';'})
    result = result.filter(proc (i: int): bool =
      tags.allIt(marks[i].tags.contains(it)))

  if args["--remove-tags"]:
    let tags = (args["--remove-tags"] ?: "").split({',', ';'})
    result = result.filter(proc (i: int): bool =
      not tags.allIt(marks[i].tags.contains(it)))

  if args["--matching"]:
    let pattern = re(args["--matching"] ?: "")
    result = result.filterIt(marks[it].summary.find(pattern).isSome)

when isMainModule:
 try:
  let doc = """
Usage:
  ptk init [options]
  ptk add [options]
  ptk add [options] <summary>
  ptk resume [options] [<id>]
  ptk amend [options] [<id>] [<summary>]
  ptk merge <timeline> [<timeline>...]
  ptk stop [options]
  ptk continue
  ptk delete <id>
  ptk (list | ls) [options]
  ptk (list | ls) tags
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
  -w --this-week          Restrict the selection to marks during this week.
  -W --last-week          Restrict the selection to marks during the last week.
  -v --verbose            Include notes in timeline entry output.
"""

# TODO: add    ptk delete [options]

  logging.addHandler(newConsoleLogger())
  let now = getLocalTime(getTime())

  # Parse arguments
  let args = docopt(doc, version = "ptk 0.10.0")

  if args["--echo-args"]: echo $args

  if args["--help"]:
    echo doc
    quit()

  # Find and parse the .ptkrc file
  let ptkrcLocations = @[
    if args["--config"]: $args["<cfgFile>"] else:"",
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
    if args["--file"]: $args["<file>"] else: "",
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

      let newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: STOP_MSG,
        notes: args["--notes"] ?: "",
        tags: (args["--tags"] ?: "").split({',', ';'}))
        
      timeline.marks.add(newMark)

      timeline.writeMarks(
        indices = @[timeline.marks.len - 2],
        includeNotes = args["--verbose"])
      echo "stopped timer"

      saveTimeline(timeline, timelineLocation)

    if args["continue"]:

      if timeline.marks.last.summary != STOP_MSG:
        echo "There is already something in progress:"
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

    if args["add"]:

      var newMark: Mark = (
        id: genUUID(),
        time: if args["--time"]: parseTime($args["--time"]) else: now,
        summary: args["<summary>"] ?: "",
        notes: args["--notes"] ?: "",
        tags: (args["--tags"] ?: "").split({',', ';'}))

      if args["--edit"]: edit(newMark)

      let prevLastIdx = timeline.marks.getLastIndex()
      timeline.marks.add(newMark)
      timeline.writeMarks(
        indices = @[prevLastIdx, timeline.marks.len - 1],
        includeNotes = args["--verbose"])

      saveTimeline(timeline, timelineLocation)

    if args["resume"]:

      var markToResumeIdx: int

      if args["<id>"]:
        markToResumeIdx = timeline.marks.findById($args["<id>"])
        if markToResumeIdx == -1: exitErr "Cannot find a mark matching " & $args["<id>"]
      else: markToResumeIdx = timeline.marks.getLastIndex()
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
      else: markIdx = timeline.marks.getLastIndex()

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
          includeNotes = args["--version"])

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
