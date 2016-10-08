## Personal Time Keeper
## ====================
##
## Simple time keeping CLI

import algorithm, docopt, json, langutils, logging, os, sequtils, strutils,
  tempfile, terminal, times, timeutils, uuids
import ptkutil

type
  Mark* = tuple[id: UUID, time: TimeInfo, summary: string, notes: string]
  Timeline* = tuple[name: string, marks: seq[Mark]]

const STOP_MSG = "STOP"

let NO_MARK: Mark = (
  id: parseUUID("00000000-0000-0000-0000-000000000000"),
  time: getLocalTime(getTime()),
  summary: "", notes: "")

const ISO_TIME_FORMAT = "yyyy:MM:dd'T'HH:mm:ss"

const TIME_FORMATS = @[
    "HH:mm", "HH:mm:ss", "HH:mm:ss",
    "yyyy:MM:dd'T'HH:mm:ss", "yyyy:MM:dd'T'HH:mm"]

#proc `$`*(mark: Mark): string =
  #return (($mark.uuid)[

proc exitErr(msg: string): void =
  fatal "ptk: " & msg
  quit(QuitFailure)

proc parseTime(timeStr: string): TimeInfo =
  for fmt in TIME_FORMATS:
    try: return parse(timeStr, fmt)
    except: discard nil

  raise newException(Exception, "unable to interpret as a date: " & timeStr)

template `%`(mark: Mark): JsonNode =
  %* {
    "id": $(mark.id),
    "time": mark.time.format(ISO_TIME_FORMAT),
    "summary": mark.summary,
    "notes": mark.notes
  }

template `%`(timeline: Timeline): JsonNode =
  %* { "name": timeline.name, "marks": timeline.marks }

proc loadTimeline(filename: string): Timeline =
  var timelineJson: JsonNode
  try: timelineJson = parseFile(filename)
  except:
    raise newException(ValueError,
      "unable to parse the timeline file as JSON: " & filename)

  var timeline: Timeline = (name: timelineJson["name"].getStr(), marks: @[])

  for markJson in timelineJson["marks"]:
    timeline.marks.add((
      id: parseUUID(markJson["id"].getStr()),
      time: parse(markJson["time"].getStr(), ISO_TIME_FORMAT),
      summary: markJson["summary"].getStr(),
      notes: markJson["notes"].getStr()))

  return timeline

proc saveTimeline(timeline: Timeline, location: string): void =
  var timelineFile: File
  try:
    timelineFile = open(location, fmWrite)
    timelineFile.writeLine(pretty(%timeline))
  except: raise newException(IOError, "unable to save changes to " & location)
  finally: close(timelineFile)

proc flexFormat(i: TimeInterval): string =
  let fmt =
    if i > 1.days: "d'd' H'h' m'm'"
    elif i >= 1.hours: "H'h' m'm'"
    elif i >= 1.minutes: "m'm' s's'"
    else: "s's'"

  return i.format(fmt)

proc writeMarks(marks: seq[Mark], includeNotes = false): void =
  let now = getLocalTime(getTime())

  let timeFormat =
    if now - marks.first.time > 1.years: "yyyy-MM-dd HH:mm"
    elif now - marks.first.time > 7.days: "MMM dd HH:mm"
    elif now - marks.first.time > 1.days: "ddd HH:mm"
    else: "HH:mm"

  var intervals: seq[TimeInterval] = @[]
  for i in 0..<marks.len - 1: intervals.add(marks[i+1].time - marks[i].time)
  intervals.add(now - marks.last.time)

  var prefixLens: seq[int] = @[]
  var longestPrefix = 0
  for i in 0..<marks.len:
    let
      mark = marks[i]
      interval = intervals[i]
      prefix = ($mark.id)[0..<8] & "  " & mark.time.format(timeFormat) & " (" & interval.flexFormat & ")"

    prefixLens.add(prefix.len)
    if prefix.len > longestPrefix: longestPrefix = prefix.len

  for i in 0..<marks.len:
    let mark = marks[i]

    if mark.summary == STOP_MSG: continue

    let duration = intervals[i].flexFormat
    setForegroundColor(stdout, fgBlack, true)
    write(stdout, ($mark.id)[0..<8])
    setForegroundColor(stdout, fgYellow)
    write(stdout, "  " & mark.time.format(timeFormat))
    setForegroundColor(stdout, fgCyan)
    write(stdout, " (" & duration & ")")
    resetAttributes(stdout)
    writeLine(stdout, spaces(longestPrefix - prefixLens[i]) & " -- " & mark.summary)

    if includeNotes and len(mark.notes.strip) > 0:
      writeLine(stdout, spaces(longestPrefix) & mark.notes)
      writeLine(stdout, "")

proc formatMark(mark: Mark, nextMark = NO_MARK, timeFormat = ISO_TIME_FORMAT, includeNotes = false): string =

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

proc doInit(timelineLocation: string): void =

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

proc edit(mark: var Mark): void =
  var
    tempFile: File
    tempFileName: string

  try:
    (tempFile, tempFileName) = mkstemp("timestamp-mark-", ".txt", "", fmWrite)
    tempFile.writeLine(
      """# Edit the time, mark, and notes below. Any lines starting with '#' will be
# ignored. When done, save the file and close the editor.""")
    tempFile.writeLine(mark.time.format(ISO_TIME_FORMAT))
    tempFile.writeLine(mark.summary)
    tempFile.writeLine(
      """# Everything from the line below to the end of the file will be considered
# notes for this timeline mark.""")

    close(tempFile)

    discard os.execShellCmd "$EDITOR " & tempFileName & " </dev/tty >/dev/tty"

    var
      readTime = false
      readSummary = false

    for line in lines tempFileName:
      if strip(line)[0] == '#': continue
      elif not readTime: mark.time = parseTime(line); readTime = true
      elif not readSummary: mark.summary = line; readSummary = true
      else: mark.notes &= line

  finally: close(tempFile)

when isMainModule:
 try:
  let doc = """
Usage:
  ptk init [options]
  ptk add [options]
  ptk add [options] <summary>
  ptk ammend [options] <id> [<summary>]
  ptk stop [options]
  ptk continue
  ptk delete <id>
  ptk list [options]
  ptk sum-time --ids <ids>...
  ptk sum-time [options] [<firstId>] [<lastId>]
  ptk (-V | --version)
  ptk (-h | --help)

Options:

  -f --file <file>        Use the given timeline file.
  -c --config <cfgFile>   Use <cfgFile> as configuration for the CLI.
  -t --time <time>        For add and ammend, use this time instead of the current time.
  -n --notes <notes>      For add and ammend, set the notes for a time mark.
  -V --version            Print the tool's version information.
  -e --edit               Open the mark in an editor.
  -a --after <after>      Restrict the selection to marks after <after>.
  -b --before <before>    Restrict the selection to marks after <before>.
  -h --help               Print this usage information.
  -v --verbose            Include notes in timeline entry output.
  -E --echo-args          Echo the program's understanding of it's arguments.
"""

# TODO: add    ptk delete [options]

  logging.addHandler(newConsoleLogger())

  # Parse arguments
  let args = docopt(doc, version = "ptk 0.1.0")

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

  else:

    if not fileExists(timelineLocation):
      raise newException(IOError,
        "time log file doesn't exist: " & timelineLocation)

    var timeline = loadTimeline(timelineLocation)

    if args["stop"]:

      let newMark = (
        id: genUUID(),
        time:
          if args["--time"]: parseTime($args["--time"])
          else: getLocalTime(getTime()),
        summary: STOP_MSG,
        notes: args["--notes"] ?: "")
        
      timeline.marks.add(newMark)
      writeMarks(
        marks = timeline.marks[timeline.marks.len - 2..<timeline.marks.len],
        includeNotes = args["--verbose"])
      echo "stopped timer"

      saveTimeline(timeline, timelineLocation)

    if args["continue"]:

      if timeline.marks.last.summary != STOP_MSG:
        echo "There is already something in progress:"
        writeMarks(
          marks = @[timeline.marks.last],
          includeNotes = args["--verbose"])
        quit(0)

      let prevMark = timeline.marks[timeline.marks.len - 2]
      var newMark: Mark = (
        id: genUUID(),
        time:
          if args["--time"]: parseTime($args["--time"])
          else: getLocalTime(getTime()),
        summary: prevMark.summary,
        notes: prevMark.notes)

      timeline.marks.add(newMark)
      writeMarks(marks = @[newMark], includeNotes = args["--verbose"])

      saveTimeline(timeline, timelineLocation)

    if args["add"]:

      var newMark: Mark = (
        id: genUUID(),
        time:
          if args["--time"]: parseTime($args["--time"])
          else: getLocalTime(getTime()),
        summary: args["<summary>"] ?: "",
        notes: args["--notes"] ?: "")

      if args["--edit"]: edit(newMark)

      timeline.marks.add(newMark)
      writeMarks(marks = @[newMark], includeNotes = args["--verbose"])

      saveTimeline(timeline, timelineLocation)

    if args["ammend"]:

      # Note, this returns a copy, not a reference to the mark in the seq.
      let markIdx = timeline.marks.findById($args["<id>"])
      var mark = timeline.marks[markIdx]
      
      if args["<summary>"]: mark.summary = $args["<summary>"]
      if args["--notes"]: mark.notes = $args["<notes>"]
      if args["--time"]:
        try: mark.time = parseTime($args["--time"])
        except: raise newException(ValueError,
          "invalid value for --time: " & getCurrentExceptionMsg())

      if args["--edit"]: edit(mark)

      echo formatMark(
        mark = mark,
        timeFormat = "HH:mm",
        includeNotes = args["--verbose"])

      timeline.marks.delete(markIdx)
      timeline.marks.insert(mark, markIdx)
      saveTimeline(timeline, timelineLocation)

    if args["delete"]:

      let markIdx = timeline.marks.findById($args["<id>"])
      timeline.marks.delete(markIdx)
      saveTimeline(timeline, timelineLocation)

    if args["list"]:

      var marks = timeline.marks

      if args["--after"]:
        var startTime: TimeInfo
        try: startTime = parseTime($args["--after"])
        except: raise newException(ValueError,
          "invalid value for --after: " & getCurrentExceptionMsg())
        marks = marks.filter(proc(m: Mark): bool = m.time > startTime)

      if args["--before"]:
        var endTime: TimeInfo
        try: endTime = parseTime($args["--before"])
        except: raise newException(ValueError,
          "invalid value for --before: " & getCurrentExceptionMsg())
        marks = marks.filter(proc(m: Mark): bool = m.time < endTime)

      marks = marks.sorted(proc(a, b: Mark): int = cmp(a.time, b.time))

      writeMarks(marks = marks, includeNotes = args["--version"])

    if args["sum-time"]:
    
      var intervals: seq[TimeInterval] = @[]

      if args["--ids"]:
        for id in args["<ids>"]:
          let markIdx = timeline.marks.findById(id)
          if markIdx == -1:
            warn "ptk: could not find mark for id " & id
          elif markIdx == timeline.marks.len - 1:
            intervals.add(getLocalTime(getTime()) - timeline.marks.last.time)
          else:
            intervals.add(timeline.marks[markIdx + 1].time - timeline.marks[markIdx].time)

      else:

        var startIdx = 0
        var endIdx = timeline.marks.len - 1

        if args["<firstId>"]:
          startIdx = max(timeline.marks.findById($args["<firstId>"]), 0)

        if args["<lastId>"]:
          let idx = timeline.marks.findById($args["<firstId>"])
          if (idx > 0): endIdx = idx

        if args["--after"]:
          var startTime: TimeInfo
          try: startTime = parseTime($args["--after"])
          except: raise newException(ValueError,
            "invalid value for --after: " & getCurrentExceptionMsg())
          let marks = timeline.marks.filter(proc(m: Mark): bool = m.time > startTime)

          let idx = timeline.marks.findById($marks.first.id)
          if idx > startIdx: startIdx = idx

        if args["--before"]:
          var endTime: TimeInfo
          try: endTime = parseTime($args["--before"])
          except: raise newException(ValueError,
            "invalid value for --after: " & getCurrentExceptionMsg())
          let marks = timeline.marks.filter(proc(m: Mark): bool = m.time < endTime)

          let idx = timeline.marks.findById($marks.last.id)
          if idx < endIdx: endIdx = idx

        for idx in startIdx..<min(endIdx, timeline.marks.len - 1):
          if timeline.marks[idx].summary == STOP_MSG: continue # don't count stops
          intervals.add(timeline.marks[idx + 1].time - timeline.marks[idx].time)

        if endIdx == timeline.marks.len - 1 and
           timeline.marks.last.summary != STOP_MSG:
          intervals.add(getLocalTime(getTime()) - timeline.marks.last.time)

      if intervals.len == 0:
        echo "ptk: no marks found"

      else:
        let total = foldl(intervals, a + b)
        echo total.flexFormat
 
 except:
  fatal "ptk: " & getCurrentExceptionMsg()
  quit(QuitFailure)
