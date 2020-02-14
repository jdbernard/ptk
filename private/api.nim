## Personal Time Keeping API Interface
## ===================================

import asyncdispatch, base64, bcrypt, cliutils, docopt, jester, json, logging,
  ospaths, sequtils, strutils, os, tables, times, uuids

import nre except toSeq

import ./models
import ./util
import ./version

type
  PtkUser* = object
    username*, salt*, pwdhash*, timelinePath*: string
    isAdmin*: bool

  PtkApiCfg* = object
    users*: seq[PtkUser]
    port*: int
    dataDir*: string

const TXT = "text/plain"
const JSON = "application/json"

proc parseUser(json: JsonNode): PtkUser =
  result = Ptkuser(
    username: json.getOrFail("username").getStr,
    salt: json.getOrFail("salt").getStr,
    pwdHash: json.getOrFail("pwdhash").getStr,
    timelinePath: json.getOrFail("timelinePath").getStr,
    isAdmin: json.getIfExists("isAdmin").getBool(false))

proc loadApiConfig*(json: JsonNode): PtkApiCfg =
  result = PtkApiCfg(
    port: parseInt(json.getIfExists("port").getStr("3280")),
    dataDir: json.getOrFail("dataDir").getStr,
    users: json.getIfExists("users").getElems(@[]).mapIt(parseUser(it)))

template halt(code: HttpCode,
              headers: RawHeaders,
              content: string): typed =
  ## Immediately replies with the specified request. This means any further
  ## code will not be executed after calling this template in the current
  ## route.
  bind TCActionSend, newHttpHeaders
  result[0] = CallbackAction.TCActionSend
  result[1] = code
  result[2] = some(headers)
  result[3] = content
  result.matched = true
  break allRoutes


template checkAuth(cfg: PtkApiCfg) =
  ## Check this request for authentication and authorization information.
  ## If the request is not authorized, this template immediately returns a
  ## 401 Unauthotized response 

  var authed {.inject.} = false
  var user {.inject.}: PtkUser = PtkUser()

  try:
    if not request.headers.hasKey("Authorization"):
      raiseEx "No auth token."

    let headerVal = request.headers["Authorization"]
    if not headerVal.startsWith("Basic "):
      raiseEx "Invalid Authorization type (only 'Basic' is supported)."

    let authVals = headerVal[6..^1].decode().split(":")

    let candidates = cfg.users.filterIt(it.username.compare(authVals[0]))
    if candidates.len != 1: raiseEx "Invalid Authorization: unknown username/password combination."

    let foundUser: PtkUser = candidates[0]
    if not compare(foundUser.pwdhash, hash(authVals[1], foundUser.salt)):
      raiseEx "Invalid Authorization: unknown username/password combination."

    user = foundUser
    authed = true

  except:
    stderr.writeLine "Auth failed: " & getCurrentExceptionMsg()
    halt(
      Http401,
      @{"Content-Type": TXT, "WWW_Authenticate": "Basic" },
      getCurrentExceptionMsg())

proc parseAndRun(user: PtkUser, cmd: string, params: Table[string, string]): string =

  var args = queryParamsToCliArgs(params)
  args = @[cmd, "--file", user.timelinePath] & args

  info "args: \n" & args.join(" ")

  let execResult = execWithOutput("ptk", ".", args)
  if execResult[2] != 0: raiseEx(stripAnsi($execResult[0] & "\n" & $execResult[1]))
  else: return stripAnsi(execResult[0])

proc apiParseUser(json: JsonNode): PtkUser =
  let salt = genSalt(12)

  return PtkUser(
    username: json.getOrFail("username").getStr,
    pwdhash: json.getOrFail("password").getStr.hash(salt),
    salt: salt,
    timelinePath: json.getIfExists("timelinePath").getStr(""),
    isAdmin: false)

proc apiParseMark(json: JsonNode): Mark =

  if not json.hasKey("id"): json["id"] = %($genUUID())
  if not json.hasKey("summary"): raiseEx "cannot parse mark: missing 'summary'"
  if not json.hasKey("time"): json["time"] = %(getTime().local.format(ISO_TIME_FORMAT))

  return parseMark(json)

proc patchMark(m: Mark, j: JsonNode): Mark =
  result = m

  if j.hasKey("summary"): result.summary = j["summary"].getStr
  if j.hasKey("notes"): result.notes = j["notes"].getStr
  if j.hasKey("tags"):
    result.tags = j["tags"].getElems(@[]).map(proc (t: JsonNode): string = t.getStr())
  if j.hasKey("time"): result.time = parse(j["time"].getStr(), ISO_TIME_FORMAT)

proc start_api*(cfg: PtkApiCfg) =

  var stopFuture = newFuture[void]()

  settings:
    port = Port(cfg.port)
    appName = "/api"

  routes:

    get "/version": resp("ptk v" & PTK_VERSION, TXT)

    get "/marks":
      checkAuth(cfg)

      try: resp(parseAndRun(user, "list", request.params), TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/continue":
      checkAuth(cfg)

      try: resp(parseAndRun(user, "continue", request.params), TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/sum-time":
      checkAuth(cfg)

      try: resp(parseAndRun(user, "sum-time", request.params), TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/mark":
      checkAuth(cfg)

      var newMark: Mark
      try: newMark = apiParseMark(parseJson(request.body))
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      try:
        var timeline = loadTimeline(user.timelinePath)
        timeline.marks.add(newMark)
        saveTimeline(timeline, user.timelinePath)
        resp(Http201, "ok", TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/stop":
      checkAuth(cfg)

      var newMark: Mark
      try:
        var json = parseJson(request.body)
        json["summary"] = %STOP_MSG
        json["id"] = %($genUUID())
        newMark = apiParseMark(json)
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      try:
        var timeline = loadTimeline(user.timelinePath)
        timeline.marks.add(newMark)
        saveTimeline(timeline, user.timelinePath)
        resp(Http201, "ok", TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/resume/@id":
      checkAuth(cfg)

      var timeline: Timeline
      try: timeline = loadTimeline(user.timelinePath)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

      var newMark: Mark
      try:
        let origMarkIdx = timeline.marks.findById(@"id")
        if origMarkIdx < 0: resp(Http404, "no mark for id: " & @"id", TXT)
        let origMark = timeline.marks[origMarkIdx]

        newMark = origMark
        newMark.id = genUUID()
        newMark.time = getTime().local
        newMark = newMark.patchMark(parseJson(request.body))
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      try:
        timeline.marks.add(newMark)
        timeline.saveTimeline(user.timelinePath)
        resp(Http201, "ok", TXT)

      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/amend/@id":
      checkAuth(cfg)

      try:
        var timeline = loadTimeline(user.timelinePath)

        let idx = timeline.marks.findById(@"id")
        if idx < 0: resp(Http404, "no mark for id: " & @"id", TXT)

        timeline.marks[idx] = timeline.marks[idx].patchMark(parseJson(request.body))

        timeline.saveTimeline(user.timelinePath)
        resp(Http202, $(%timeline.marks[idx]), JSON)

      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/users":
      checkAuth(cfg)
      if not user.isAdmin: resp(Http403, "insufficient permission", TXT)

      var newUser: PtkUser
      try: newUser = apiParseUser(parseJson(request.body))
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      if cfg.users.anyIt(it.username == newUser.username):
        resp(Http409, "user already exists", TXT)

      newUser.timelinePath = cfg.dataDir / newUser.username & ".timeline.json"

      try:
        discard parseAndRun(newUser, "init", initTable[string,string]())
        # TODO: save updated config!
        # cfg.users.add(newUser)
        resp(Http200, "ok", TXT)

      except: resp(Http500, "could not init new user timeline", TXT)

  waitFor(stopFuture)
