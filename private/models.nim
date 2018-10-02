import algorithm, json, sequtils, strutils, times, timeutils, uuids

type
  Mark* = tuple[id: UUID, time: DateTime, summary: string, notes: string, tags: seq[string]]
    ## Representation of a single mark on the timeline.

  Timeline* = tuple[name: string, marks: seq[Mark]]
    ## Representation of a timeline: a name and sequence of Marks.

const STOP_MSG* = "STOP"

let NO_MARK*: Mark = (
  id: parseUUID("00000000-0000-0000-0000-000000000000"),
  time: fromUnix(0).local,
  summary: "", notes: "", tags: @[])

const ISO_TIME_FORMAT* = "yyyy-MM-dd'T'HH:mm:ss"
  ## The canonical time format used by PTK.

const TIME_FORMATS* = @[
    "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm",
    "MM-dd'T'HH:mm:ss", "MM-dd HH:mm:ss",
    "MM-dd'T'HH:mm", "MM-dd HH:mm",
    "HH:mm:ss", "H:mm:ss", "H:mm", "HH:mm" ]
  ## Other time formats that PTK will accept as input.


proc parseTime*(timeStr: string): DateTime =
  ## Helper to parse time strings trying multiple known formats. 
  for fmt in TIME_FORMATS:
    try: return parse(timeStr, fmt)
    except: discard nil

  raise newException(Exception, "unable to interpret as a date: " & timeStr)

proc parseMark*(json: JsonNode): Mark =

  # TODO: an incorrect time format that was used in version 0.6 and prior.
  # Version 0.7 between 1.0 support this format on read only and will write
  # out the correct  format (so they can be used to convert older timelines).
  var time: DateTime
  try: time = parse(json["time"].getStr(), ISO_TIME_FORMAT)
  except: time = parse(json["time"].getStr(), "yyyy:MM:dd'T'HH:mm:ss")

  return (
      id: parseUUID(json["id"].getStr()),
      time: time, #parse(json["time"].getStr(), ISO_TIME_FORMAT),
      summary: json["summary"].getStr(),
      notes: json["notes"].getStr(),
      tags: json["tags"].getElems(@[]).map(proc (t: JsonNode): string = t.getStr()))

template `%`*(mark: Mark): JsonNode =
  %* {
    "id": $(mark.id),
    "time": mark.time.format(ISO_TIME_FORMAT),
    "summary": mark.summary,
    "notes": mark.notes,
    "tags": mark.tags
  }

template `%`*(timeline: Timeline): JsonNode =
  %* { "name": timeline.name, "marks": timeline.marks }

proc loadTimeline*(filename: string): Timeline =
  ## Load a timeline from a file. Expects a path to a file (can be relative or
  ## absolute) and returns a Timeline. The marks in the timeline are guaranteed
  ## to be ordered by time.

  var timelineJson: JsonNode
  try: timelineJson = parseFile(filename)
  except:
    raise newException(ValueError,
      "unable to parse the timeline file as JSON: " & filename)

  var timeline: Timeline = (name: timelineJson["name"].getStr(), marks: @[])

  for markJson in timelineJson["marks"]: timeline.marks.add(parseMark(markJson))

  timeline.marks = timeline.marks.sorted(
    proc(a, b: Mark): int = cmp(a.time, b.time))

  return timeline

proc saveTimeline*(timeline: Timeline, location: string): void =
  ## Write the timeline to disk at the file location given.

  var timelineFile: File
  try:
    timelineFile = open(location, fmWrite)
    timelineFile.writeLine(pretty(%timeline))
  except: raise newException(IOError, "unable to save changes to " & location)
  finally: close(timelineFile)

proc findById*(marks: seq[Mark], id: string): int =
  var idx = 0
  for mark in marks:
    if startsWith($mark.id, id): return idx
    inc(idx)

  return -1

proc getLastIndex*(marks: seq[Mark]): int =
  ## Find and return the index of the last Mark that was not a STOP mark.
  ## Returns -1 if there is no such last mark.

  var idx = marks.len - 1
  while idx >= 0 and marks[idx].summary == STOP_MSG: idx -= 1
  if idx < 0: result = -1
  else: result = idx


