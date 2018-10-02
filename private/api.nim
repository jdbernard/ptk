## Personal Time Keeping API Interface
## ===================================

import asyncdispatch, base64, bcrypt, cliutils, docopt, jester, json, logging,
  ospaths, sequtils, strutils, os
import nre except toSeq

import ./models

type
  PtkUser* = object
    username*, salt*, pwdhash*, timelinePath: string
    isAdmin*: bool

  PtkApiCfg* = object
    users*: seq[PtkUser]
    port*: int
    dataDir*: string

const TXT = "text/plain"
const JSON = "application/json"

proc raiseEx(reason: string): void = raise newException(Exception, reason)

template checkAuth(cfg: PtkApiCfg) =
  ## Check this request for authentication and authorization information.
  ## If the request is not authorized, this template sets up the 401 response
  ## correctly. The calling context needs only to return from the route.

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
    response.data[0] = CallbackAction.TCActionSend
    response.data[1] = Http401
    response.data[2]["WWW_Authenticate"] = "Basic"
    response.data[2]["Content-Type"] = TXT
    response.data[3] = getCurrentExceptionMsg()

proc parseAndRun(user: PtkUser, cmd: string, params: StringTableRef): string =

  var args = queryParamsToCliArgs(params)
  args = @[cmd, "--file", user.timelinePath] & args

  info "args: \n" & args.join(" ")

  let execResult = execWithOutput("ptk", ".", args)
  if execResult[2] != 0: raiseEx(stripAnsi($execResult[0] & "\n" & $execResult[1]))
  else: return stripAnsi(execResult[0])

proc getOrFail(n: JsonNode, key: string, objName: string = ""): JsonNode =
  ## convenience method to get a key from a JObject or raise an exception
  if not n.hasKey(key): raiseEx objName & " missing key '" & key & "'"
  return n[key]

proc getIfExists(n: JsonNode, key: string): JsonNode =
  ## convenience method to get a key from a JObject or return null
  result = if n.hasKey(key): n[key]
           else: newJNull()

proc parseUser(json: JsonNode): PtkUser =
  let salt = gensalt(12)

  return PtkUser(
    username: json.getOrFail("username").getStr,
    pwdhash: json.getOrFail("password").getStr.hash(salt),
    salt: salt,
    timelinePath: json.getIfExists("timelinePath").getStr(""),
    isAdmin: false)

proc start*(cfg: PtkApiCfg) =

  var stopFuture = newFuture[void]()

  settings:
    port = Port(cfg.port)
    appName = "/api"

  routes:

    get "/ping": resp("pong", TXT)

    get "/marks":
      checkAuth(cfg); if not authed: return true

      try: resp(parseAndRun(user, "list", request.params), TXT)
      except: resp(Http500, getCurrentExceptionMsg(), TXT)

    post "/mark":
      checkAuth(cfg); if not authed: return true

      var newMark: Mark
      try: newMark = parseMark(parseJson(request.body))
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      var params = newStringTable

    post "/users":
      checkAuth(cfg); if not authed: return true
      if not user.isAdmin: resp(Http403, "insufficient permission", TXT)

      var newUser: PtkUser
      try: newUser = parseUser(parseJson(request.body))
      except: resp(Http400, getCurrentExceptionMsg(), TXT)

      if cfg.users.anyIt(it.username == newUser.username):
        resp(Http409, "user already exists", TXT)

      newUser.timelinePath = cfg.dataDir / newUser.username & ".timeline.json"

      try:
        discard parseAndRun(newUser, "init", newStringTable())
        # TODO: save updated config!
        # cfg.users.add(newUser)
        resp(Http200, "ok", TXT)

      except: resp(Http500, "could not init new user timeline", TXT)
