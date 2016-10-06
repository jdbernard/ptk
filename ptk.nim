## Personal Time Keeper
## ====================
##
## Simple time keeping CLI

import algorithm, docopt, json, langutils, logging, os, sequtils, strutils,
  tempfile, times, uuids

type
  Mark* = tuple[id: UUID, time: TimeInfo, summary: string, notes: string]
  Timeline* = tuple[name: string, marks: seq[Mark]]

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

  var timeline: Timeline = (name: $timelineJson["name"], marks: @[])

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

proc formatMark(mark: Mark, nextMark = NO_MARK, timeFormat = ISO_TIME_FORMAT, includeNotes = false): string =

  let nextTime =
    if nextMark == NO_MARK: getLocalTime(getTime())
    else: mark.time

  # TODO: pick up here calculating the time between marks

  let prefix = ($mark.id)[0..<8] & "  " & mark.time.format(timeFormat) & "  " 
  result = prefix & mark.summary
  if includeNotes and len(mark.notes.strip()) > 0:
    let wrappedNotes = wordWrap(s = mark.notes, maxLineWidth = 80 - len(prefix))
    for line in splitLines(wrappedNotes):
      result &= "\x0D\x0A" & spaces(len(prefix)) & line
    result &= "\x0D\x0A"

proc findMarkById(timeline: Timeline, id: string): auto =
  var idx = 0
  for mark in timeline.marks:
    if startsWith($mark.id, id): return (mark, idx)
    inc(idx)

  return (NO_MARK, -1)

proc doInit(timelineLocation: string): void =

  stdout.write "Time log name [New Timeline]: "
  let name = stdin.readLine()

  let timeline = %*
    { "name": if name.len > 0: name else: "New Timeline",
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
  ptk list [options] [<start>] [<end>]
  ptk ammend [options] <id> [<summary>]
  ptk delete <id>
  ptk (-V | --version)
  ptk (-h | --help)

Options:

  -f --file   <file>      Use the given time keeper file.
  -c --config <cfgFile>   Use <cfgFile> as configuration for the CLI.
  -t --time <time>        For add and ammend, use this time instead of the current time.
  -n --notes <notes>      For add and ammend, set the notes for a time mark.
  -V --version            Print the tool's version information.
  -e --edit               Open the mark in an editor.
  -h --help               Print this usage information.
  -v --verbose            Include notes in timeline entry output.
"""

  logging.addHandler(newConsoleLogger())

  # Parse arguments
  let args = docopt(doc, version = "ptk 0.1.0")

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
      cfgFile.write("{}")
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

    var timeline = parseFile(timelineLocation)

    if args["add"]:

      var newMark: Mark = (
        id: genUUID(),
        time:
          if args["--time"]: parseTime($args["<time>"])
          else: getLocalTime(getTime()),
        summary: args["<summary>"] ?: "",
        notes: args["--notes"] ?: "")

      if args["--edit"]: edit(newMark)

      timeline["marks"].add(%newMark)
      echo formatMark(
        mark = newMark,
        timeFormat = "HH:mm",
        includeNotes = args["--verbose"])

      var timelineFile: File
      try:
        timelineFile = open(timelineLocation, fmWrite)
        timelineFile.writeLine(pretty(%timeline))
      finally: close(timelineFile)

    if args["ammend"]:

      var timeline = loadTimeline(timelineLocation)

      # Note, this returns a copy, not a reference to the mark in the seq.
      var (mark, markIdx) = timeline.findMarkById($args["<id>"])
      
      if args["<summary>"]: mark.summary = $args["<summary>"]
      if args["--notes"]: mark.notes = $args["<notes>"]
      if args["--time"]:
        try: mark.time = parseTime($args["<time>"])
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

      var timeline = loadTimeline(timelineLocation)

      var (mark, markIdx) = timeline.findMarkById($args["<id>"])
      timeline.marks.delete(markIdx)
      saveTimeline(timeline, timelineLocation)

    if args["list"]:

      let timeline = loadTimeline(timelineLocation)

      var marks = timeline.marks

      if args["<start>"]:
        var startTime: Time
        try: startTime = parseTime($args["<start>"]).toTime
        except: raise newException(ValueError,
          "invalid value for --start: " & getCurrentExceptionMsg())
        marks = marks.filter(proc(m: Mark): bool = m.time.toTime > startTime)

      if args["<end>"]:
        var endTime: Time
        try: endTime = parseTime($args["<end>"]).toTime
        except: raise newException(ValueError,
          "invalid value for --end: " & getCurrentExceptionMsg())
        marks = marks.filter(proc(m: Mark): bool = m.time.toTime < endTime)

      marks = marks.sorted(proc(a, b: Mark): int = cast[int](a.time.toTime - b.time.toTime))

      #for i in 0..<marks.high-1:
      #  echo formatMark(
      for mark in marks:
        echo formatMark(
          mark = mark,
          timeFormat = "HH:mm",
          includeNotes = args["--verbose"])
 except:
  fatal "ptk: " & getCurrentExceptionMsg()
  quit(QuitFailure)
