import macros, lua, strutils
export lua, macros

type
  elemTup = tuple[node: NimNode, name: string, kind: NimNodeKind]
  
  argPair = object
    mName, mType: NimNode
      
  bindFlag = enum
    nlbUseLib
    nlbRegisterObject

  bindFlags = set[bindFlag]

  ovProcElem = ref object
    retType: NimNode
    params: seq[argPair]
  
  ovProc = ref object
    numArgs: int
    procs: seq[ovProcElem]

  ovList = seq[ovProc]
  
  ovFlag = enum
    ovfUseObject
    ovfUseRet
    
  ovFlags = set[ovFlag]
  
const GLOBAL* = "GLOBAL"

#counter that will be used to generate unique intermediate macro name
#and avoid name collision
var
  macroCount {.compileTime.} = 0
  proxyCount {.compileTime.} = 0
  objectCount {.compileTime.} = 0
  echoGenCode {.compileTime.} = false

#inside macro, const bool become nnkIntLit, that's why we need use
#this trick to test for bool type using 'when internalTestForBOOL(n)'
proc internalTestForBOOL*[T](a: T): bool {.compileTime.} =
  when a is bool: result = true
  else: result = false

#call this with true or false to enable/disable debug mode
macro nimLuaDebug*(mode: bool): stmt =
  if mode.kind == nnkSym and $mode == "true":
    echoGenCode = true
  else:
    echoGenCode = false
  result = newNimNode(nnkStmtList)
  
proc parseCode(s: string): NimNode {.compileTime.} =
  result = parseStmt(s)
  if echoGenCode:
    echo s

#split something like 'ident -> "newName"' into tuple
proc splitElem(n: NimNode): elemTup {.compileTime.} =
  let
    op  = n[0]
    lhs = n[1]
    rhs = n[2]

  if $op != "->":
    error("wrong operator, must be '->' and not '" & $op & "'")
  if lhs.kind notin {nnkIdent, nnkAccQuoted}:
    error("param must be an identifier and not " & $lhs.kind)
  if rhs.kind notin {nnkStrLit, nnkIdent}:
    error("alias must be string literal and not " & $rhs.kind)

  if lhs.kind == nnkAccQuoted:
    result = (lhs[0], $rhs, nnkAccQuoted)
  else:
    result = (lhs, $rhs, nnkIdent)

#helper proc to flatten nnkStmtList
proc unwindList(arg: NimNode, elemList: var seq[elemTup]) {.compileTime.} =
  for i in 0..arg.len-1:
    let n = arg[i]
    case n.kind:
    of nnkIdent:
      let elem = (node: n, name: $n, kind: n.kind)
      elemList.add elem
    of nnkAccQuoted:
      let elem = (node: n[0], name: "`" & $n[0] & "`", kind: n.kind)
      elemList.add elem
    of nnkInfix:
      elemList.add splitElem(n)
    else:
      error("wrong param type")

#here is the factory of second level macro that will be expanded to utilize bindSym
proc genProxyMacro(arg: NimNode, opts: bindFlags, proxyName: string): NimNode {.compileTime.} =
  let
    useLib = nlbUseLib in opts
    registerObject = nlbRegisterobject in opts

  var
    luaCtx   = ""
    libName  = ""
    objectName = ""
    elemList = newSeq[elemTup]()

  for i in 0..arg.len-1:
    let n = arg[i]
    case n.kind
    of nnkSym:
      if i == 0: luaCtx = $n
      else:
        echo arg.treeRepr
        error("param " & $i & " must be an identifier, not symbol")
    of nnkStrLit:
      if i == 1 and useLib: libName = n.strVal
      else:
        echo arg.treeRepr
        error("param " & $i & " must be an identifier, not string literal")
    of nnkIdent:
      if i == 1 and $n == "GLOBAL" and useLib: libName = $n
      elif i == 1 and registerObject: objectName = $n
      else:
        let elem = (node: n, name: $n, kind: n.kind)
        elemList.add elem
    of nnkAccQuoted:
      let elem = (node: n[0], name: "`" & $n[0] & "`", kind: n.kind)
      elemList.add elem
    of nnkInfix:
      elemList.add splitElem(n)
    of nnkStmtList:
      unwindList(n, elemList)
    else:
      echo n.treeRepr
      error("wrong param type")

  if luaCtx == "":
    error("need luaState as first param")

  if libName != "" or useLib:
    libName = "\"$1\", " % [libName]

  #generate intermediate macro to utilize bindSym that can only accept string literal
  let macroName = "NLB$1$2" % [proxyName, $macroCount]
  var nlb = "macro " & macroName & "(): stmt =\n"
  if registerObject:
    nlb.add "  let objSym = bindSym\"$1\"\n" % [objectName]
  nlb.add "  let elemList = [\n"

  var i = 0
  for k in elemList:
    let comma = if i < elemList.len-1: "," else: ""
    nlb.add "    (bindSym\"$1\", \"$2\", $3)$4\n" % [$k.node, k.name, $k.kind, comma]
    inc i

  nlb.add "  ]\n"

  if registerObject:
    nlb.add "  result = bind$1Impl(\"$2\", objSym, elemList)\n" % [proxyName, luaCtx]
  else:
    nlb.add "  result = bind$1Impl(\"$2\", $3 elemList)\n" % [proxyName, luaCtx, libName]

  nlb.add macroName & "()\n"
  result = parseCode(nlb)
  inc macroCount

#flatten formal param into seq
proc paramsToArgList(params: NimNode): seq[argPair] {.compileTime.} =
  var argList = newSeq[argPair]()
  for i in 1..params.len-1:
    let arg = params[i]
    let mType = arg[arg.len - 2]
    for j in 0..arg.len-3:
      argList.add(argPair(mName: arg[j], mType: mType))
  result = argList
  
#proc params and return type
proc newProcElem(retType: NimNode, params: seq[argPair]): ovProcElem {.compileTime.} =
  result = new(ovProcElem)
  result.retType = retType
  result.params = params
  
#list of overloaded proc
proc newOvProc(retType: NimNode, params: seq[argPair]): ovProc {.compileTime.} =
  var ovp = new(ovProc)
  ovp.numArgs = params.len
  ovp.procs = newSeq[ovProcElem]()
  ovp.procs.add newProcElem(retType, params)
  result = ovp
    
#add overloaded proc into ovList
proc addOvProc(ovl: var ovList, retType: NimNode, params: seq[argPair]) {.compileTime.} =
  var found = false
  for k in ovl:
    if k.numArgs == params.len:
      k.procs.add newProcElem(retType, params)
      found = true
      break
      
  if not found:
    ovl.add newOvProc(retType, params)
    
proc nimLuaPanic(L: PState): cint {.cdecl.} =
  echo "panic"

#call this before you use this library
proc newNimLua*(): PState =
  var L = newState()
  L.openLibs
  discard L.atPanic(nimLuaPanic)

  let code = """
function readonlytable(table)
   return setmetatable({}, {
     __index = table,
     __newindex = function(table, key, value) error("Attempt to modify read-only table") end,
     __metatable = false
   });
end
"""
  discard L.doString(code)
  result = L

# -------------------------------------------------------------------------
# --------------------------------- bindEnum ------------------------------
# -------------------------------------------------------------------------

proc bindEnumScoped(SL: string, s: NimNode, scopeName: string, kind: NimNodeKind): string {.compileTime.} =
  let x = getImpl(s.symbol)
  var err = false
  if x.kind != nnkTypeDef: err = true
  if x[0].kind != nnkSym: err = true
  if x[2].kind != nnkEnumTy: err = true
  if err:
    error("bindEnum: incorrect enum definition")

  let
    numEnum = x[2].len - 1
    enumName = if kind == nnkAccQuoted: "`" & $x[0] & "`" else: $x[0]

  result = "$1.getGlobal(\"readonlytable\")\n" % [SL]
  result.add "$1.createTable(0.cint, cint($2))\n" % [SL, $numEnum]

  for i in 1..numEnum:
    let
      n = x[2][i]
      sym = if n.kind == nnkAccQuoted: "`" & $n[0] & "`" else: $n
    result.add "discard $1.pushlString(\"$2\", $3)\n" % [SL, sym, $sym.len]
    result.add "when compiles($1):\n" % [sym]
    result.add "  $1.pushInteger(lua_Integer($2))\n" % [SL, sym]
    result.add "else:\n"
    result.add "  $1.pushInteger(lua_Integer($2.$3))\n" % [SL, enumName, sym]
    result.add "$1.setTable(-3)\n" % [SL]

  result.add "discard $1.pcall(1, 1, 0)\n" % [SL]
  result.add "$1.setGlobal(\"$2\")\n" % [SL, scopeName]

proc bindEnumGlobal(SL: string, s: NimNode, kind: NimNodeKind): string {.compileTime.} =
  let x = getImpl(s.symbol)
  var err = false
  if x.kind != nnkTypeDef: err = true
  if x[0].kind != nnkSym: err = true
  if x[2].kind != nnkEnumTy: err = true
  if err:
    error("bindEnum: incorrect enum definition")

  let
    numEnum = x[2].len - 1
    enumName = if kind == nnkAccQuoted: "`" & $x[0] & "`" else: $x[0]

  result = ""
  for i in 1..numEnum:
    let
      n = x[2][i]
      sym = if n.kind == nnkAccQuoted: "`" & $n[0] & "`" else: $n
    result.add "when compiles($1):\n" % [sym]
    result.add "  $1.pushInteger(lua_Integer($2))\n" % [SL, sym]
    result.add "else:\n"
    result.add "  $1.pushInteger(lua_Integer($2.$3))\n" % [SL, enumName, sym]
    result.add "$1.setGlobal(\"$2\")\n" % [SL, sym]

#this proc need to be exported because intermediate macro call this proc from
#callsite module
proc bindEnumImpl*(SL: string, arg: openArray[elemTup]): NimNode {.compileTime.} =
  var glue = ""
  for i in 0..arg.len-1:
    let n = arg[i]
    if n.name == "GLOBAL": glue.add bindEnumGlobal(SL, n.node, n.kind)
    else: glue.add bindEnumScoped(SL, n.node, n.name, n.kind)

  result = parseCode(glue)

macro bindEnum*(arg: varargs[untyped]): stmt =
  result = genProxyMacro(arg, {}, "Enum")

# -------------------------------------------------------------------------
# ----------------------------- bindFunction ------------------------------
# -------------------------------------------------------------------------

#runtime type check helper for string
proc checkNimString*(L: PState, idx: cint): string =
  if L.isString(idx) != 0: result = L.toString(idx)
  else:
    discard L.error("expected string arg")
    result = ""

#runtime type check helper for bool
proc checkNimBool*(L: PState, idx: cint): bool =
  if L.isBoolean(idx):
    result = if L.toBoolean(idx) == 0: false else: true
  else:
    discard L.error("expected bool arg")
    result = false

let
  intTypes {.compileTime.} = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64"]
  floatTypes {.compileTime.} = ["float", "float32", "float64"]

proc constructBasicArg(mType: NimNode, i: int): string {.compileTime.} =
  let argType = $mType
  for c in intTypes:
    if c == argType:
      return "L.checkInteger(" & $i & ")." & c & "\n"

  for c in floatTypes:
    if c == argType:
      return "L.checkNumber(" & $i & ")." & c & "\n"

  if argType == "string":
    return "L.checkNimString(" & $i & ")\n"

  if argType == "cstring":
    return "L.checkString(" & $i & ")\n"

  if argType == "bool":
    return "L.checkNimBool(" & $i & ")\n"

  if argType == "char":
    return "L.checkInteger(" & $i & ").chr\n"

  result = ""

proc constructComplexArg(mType: NimNode, i: int): string {.compileTime.} =

  error("unknown param type: " & $mType.kind)

  result = ""

proc constructBasicRet(mType: NimNode, procCall: string): string {.compileTime.} =
  let retType = $mType
  for c in intTypes:
    if c == retType:
      return "  L.pushInteger(lua_Integer(" & procCall & "))\n"

  for c in floatTypes:
    if c == retType:
      return "  L.pushNumber(lua_Number(" & procCall & "))\n"

  if retType == "string":
    return "  discard L.pushLiteral(" & procCall & ")\n"

  if retType == "cstring":
    return "  L.pushString(" & procCall & ")\n"

  if retType == "bool":
    return "  L.pushBoolean(" & procCall & ".cint)\n"

  if retType == "char":
    return "  L.pushInteger(lua_Integer(" & procCall & ")).chr\n"

  result = ""

proc constructComplexRet(mType: NimNode, procCall: string): string {.compileTime.} =

  error("unknown ret type: " & $mType.kind)

  result = ""

proc constructArg(mName, mType: NimNode, i: int): string {.compileTime.} =
  case mType.kind:
  of nnkSym:
    result = constructBasicArg(mType, i)
    if result == "": result = constructComplexArg(mType, i)
  else:
    error("unsupported param type: " & $mType.kind)
    echo mType.treeRepr

proc constructRet(retType: NimNode, procCall: string): string {.compileTime.} =
  case retType.kind:
  of nnkSym:
    result = constructBasicRet(retType, procCall)
    if result == "": result = constructComplexRet(retType, procCall)
  else:
    error("unsupported return type: " & $retType.kind)
    echo retType.treeRepr

proc genOvCallSingle(ovp: ovProcElem, procName, indent: string, flags: ovFlags): string {.compileTime.} =
  var glueParam = ""
  var glue = ""
  let start = if ovfUseObject in flags: 1 else: 0
  
  for i in start..ovp.params.len-1:
    let param = ovp.params[i]
    glue.add indent & "  let arg" & $i & " = " & constructArg(param.mName, param.mType, i + 1)
    glueParam.add "arg" & $i
    if i < ovp.params.len-1: glueParam.add ", "

  let procCall = if ovfUseObject in flags:
      "foo.$1($2)" % [procName, glueParam]
    else:
      procName & "(" & glueParam & ")"

  if ovfUseRet in flags:
    if ovp.retType.kind == nnkEmpty:
      glue.add indent & "  " & procCall & "\n"
      glue.add indent & "  return 0\n"
    else:
      glue.add indent & constructRet(ovp.retType, procCall)
      glue.add indent & "  return 1\n"
    
  result = glue
  
proc bindSingleFunction(n: NimNode, glueProc, procName: string): string {.compileTime.} =
  if n.kind != nnkProcDef:
    error("bindFunction: " & procName & " is not a proc")

  let params = n[3]
  let retType = params[0]
  let argList = paramsToArgList(params)
  
  var glue = "proc " & glueProc & "(L: PState): cint {.cdecl.} =\n"
  glue.add genOvCallSingle(newProcElem(retType, argList), procName, "", {ovfUseRet})
  
  result = glue
    
proc genBasicCheck(mType: NimNode, i: int): string {.compileTime.} =
  let argType = $mType
  for c in intTypes:
    if c == argType:
      return "(L.isInteger(" & $i & ") == 1)"

  for c in floatTypes:
    if c == argType:
      return "(L.isNumber(" & $i & ") == 1)"

  if argType == "string":
    return "(L.isString(" & $i & ") == 1)"

  if argType == "cstring":
    return "(L.isString(" & $i & ") == 1)"

  if argType == "bool":
    return "L.isBoolean(" & $i & ")"

  if argType == "char":
    return "(L.isInteger(" & $i & ") == 1)"

  result = ""

proc genComplexCheck(mType: NimNode, i: int): string {.compileTime.} =
  echo mType.treeRepr
  error("genComplexCheck: unknown param type: " & $mType.kind)
  result = ""
  
proc genCheckType(mName, mType: NimNode, i: int): string {.compileTime.} =
  case mType.kind:
  of nnkSym:
    result = genBasicCheck(mType, i)
    if result == "": result = genComplexCheck(mType, i)
  else:
    error("genCheckType: unsupported param type: " & $mType.kind)
    echo mType.treeRepr
    
#second level of ov proc resolution
proc genCheck(params: seq[argPair], flags: ovFlags): string {.compileTime.} =
  var glue = "    if "
  let start = if ovfUseObject in flags: 1 else: 0
  for i in start..params.len-1:
    glue.add genCheckType(params[i].mName, params[i].mType, i + 1)
    if i < params.len-1:
      glue.add " and "
    else:
      glue.add ":\n"
  result = glue
  
#overloaded proc need to be resolved by their params count and params type
#genCheck generate code to check params type
proc genOvCallMany(ovp: seq[ovProcElem], procName: string, flags: ovFlags): string {.compileTime.} =
  var glue = ""
  for ov in ovp:
    glue.add genCheck(ov.params, flags)
    glue.add genOvCallSingle(ov, procName, "    ", flags)
  result = glue

proc genOvCall(ovp: seq[ovProc], procName: string, flags: ovFlags): string {.compileTime.} =
  var glue = "  let numArgs = L.getTop().int\n"
  for k in ovp:
    glue.add "  if numArgs == $1:\n" % [$k.numArgs] #first level of ov proc resolution
    if k.procs.len == 1: 
      glue.add genOvCallSingle(k.procs[0], procName, "  ", flags)
    else: 
      glue.add genOvCallMany(k.procs, procName, flags)
  result = glue

proc bindOverloadedFunction(ov: NimNode, glueProc, procName: string): string {.compileTime.} =
  var ovl = newSeq[ovProc]()
  
  for s in children(ov):
    let n = getImpl(s.symbol)
    if n.kind != nnkProcDef:
      error("bindObject: " & procName & " is not a proc")

    let params = n[3]
    let retType = params[0]
    let argList = paramsToArgList(params)
    ovl.addOvProc(retType, argList)
  
  var glue = "proc " & glueProc & "(L: PState): cint {.cdecl.} =\n"
  glue.add genOvCall(ovl, procName, {ovfUseRet})
  glue.add "  discard L.error(\"$1: invalid param count\")\n" % [procName]
  glue.add "  return 0\n"

  result = glue

#both normal ident and backticks quoted ident converted to string
proc getAccQuotedName(n: NimNode, kind: NimNodeKind): string {.compileTime.} =
  let name = if n.kind == nnkClosedSymChoice: $n[0] else: $n
  if kind == nnkAccQuoted: result = "`" & name & "`" else: result = name

#this proc is exported because of the NLBFunc macro expansion occured on bindFunction caller module
proc bindFuncImpl*(SL, libName: string, arg: openArray[elemTup]): NimNode {.compileTime.} =
  let
    exportLib = libName != "" and libName != "GLOBAL"

  var glue = ""
  if exportLib:
    glue.add SL & ".createTable(0.cint, " & $(arg.len) & ".cint)\n"

  for i in 0..arg.len-1:
    let n = arg[i]
    if n.node.kind notin {nnkSym, nnkClosedSymChoice}:
      error("bindFunction: arg[" & $i & "] need symbol not " & $n.node.kind)

    let
      procName = getAccQuotedName(n.node, n.kind)
      glueProc = "nimLUAproxy" & $proxyCount
      exportedName = n.name

    if n.node.kind == nnkSym:
      glue.add bindSingleFunction(getImpl(n.node.symbol), glueProc, procName)
    else: #nnkClosedSymChoice
      glue.add bindOverloadedFunction(n.node, glueProc, procName)

    if exportLib:
      glue.add "discard " & SL & ".pushString(\"" & exportedName & "\")\n"
      glue.add SL & ".pushCfunction(" & glueProc & ")\n"
      glue.add SL & ".setTable(-3)\n"
    else:
      glue.add SL & ".pushCfunction(" & glueProc & ")\n"
      glue.add SL & ".setGlobal(\"" & exportedName & "\")\n"

    inc proxyCount

  if exportLib:
    glue.add SL & ".setGlobal(\"" & libName & "\")"

  result = parseCode(glue)

#call this macro with following params pattern:
# * bindFunction(luaState, "libName", ident1, ident2, .., identN)
#     -> export nim function(s) with lua scope named "libName"
# * bindFunction(luaState, ident1, ident2, .., identN)
#     -> export nim function(s) to lua global scope

macro bindFunction*(arg: varargs[untyped]): stmt =
  result = genProxyMacro(arg, {nlbUSeLib}, "Func")

# ----------------------------------------------------------------------
# ----------------------------- bindConst ------------------------------
# ----------------------------------------------------------------------

proc constructConstBasic(SL, name, indent: string, n: NimNode): string {.compileTime.} =
  if n.kind in {nnkCharLit..nnkUInt64Lit}:
    var nlb = indent & "when not internalTestForBOOL($1[0]):\n" % [name]
    nlb.add indent & "  $1.pushInteger(lua_Integer($2[i]))\n" % [SL, name]
    nlb.add indent & "else:\n"
    nlb.add indent & "  $1.pushBoolean($2[i].cint)\n" % [SL, name]
    return nlb

  if n.kind in {nnkFloatLit..nnkFloat64Lit}:
    return indent & "$1.pushNumber(lua_Number($2[i]))\n" % [SL, name]

  if n.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return indent & "discard $1.pushLString($2[i], $2[i].len)\n" % [SL, name]

  echo "C: ", treeRepr(n)
  result = ""

proc constructConstParBasic(SL, indent: string, n: NimNode, name: string, idx: int): string {.compileTime.} =
  if n.kind in {nnkCharLit..nnkUInt64Lit}:
    var nlb = indent & "when not internalTestForBOOL($2[0][0]):\n" % [SL, name]
    nlb.add indent & "  $1.pushInteger(lua_Integer($2[i][$3]))\n" % [SL, name, $idx]
    nlb.add indent & "else:\n"
    nlb.add indent & "  $1.pushBoolean($2[i][$3].cint)\n" % [SL, name, $idx]
    return nlb

  if n.kind in {nnkFloatLit..nnkFloat64Lit}:
    return indent & "$1.pushNumber(lua_Number($2[i][$3]))\n" % [SL, name, $idx]

  if n.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return indent & "discard $1.pushLString($2[i][$3], $2[i][$3].len)\n" % [SL, name, $idx]

  echo "B: ", treeRepr(n)
  result = ""

proc constructConstPar(SL, name, indent: string, n: NimNode): string {.compileTime.} =
  result = constructConstParBasic(SL, indent, n[0], name, 0)
  result.add constructConstParBasic(SL, indent, n[1], name, 1)

proc constructConst(SL: string, n: NimNode, name: string): string {.compileTime.} =
  if n.kind in {nnkCharLit..nnkUInt64Lit}:
    var nlb = "when not internalTestForBOOL($1):\n" % [name]
    nlb.add "  $1.pushInteger(lua_Integer($2))\n" % [SL, $(n.intVal)]
    nlb.add "else:\n"
    nlb.add "  $1.pushBoolean($2.cint)\n" % [SL, $(n.intVal)]
    return nlb

  if n.kind in {nnkFloatLit..nnkFloat64Lit}:
    return "$1.pushNumber(lua_Number($2))\n" % [SL, $(n.floatVal)]

  if n.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    return "discard $1.pushLString(\"$2\", $3)\n" % [SL, n.strVal, $(n.strVal.len)]

  if n.kind == nnkBracket:
    if n[0].kind in {nnkCharLit..nnkTripleStrLit}:
      var nlb = "$1.createTable($2, 0)\n" % [SL, $n.len]
      nlb.add "for i in 0..$1:\n" % [$(n.len-1)]
      nlb.add constructConstBasic(SL, name, "  ", n[0])
      nlb.add "  $1.rawSeti(-2, i.cint)\n" % [SL]
      return nlb
    elif n[0].kind in {nnkPar}:
      if n[0].len == 2:
        var nlb = "$1.createTable(0, $2)\n" % [SL, $n.len]
        nlb.add "for i in 0..$1:\n" % [$(n.len-1)]
        nlb.add constructConstPar(SL, name, "  ", n[0])
        nlb.add "  $1.setTable(-3)\n" % [SL]
        return nlb

  echo "A: ", treeRepr(n)
  result = ""

proc bindConstImpl*(SL, libName: string, arg: openArray[elemTup]): NimNode {.compileTime.} =
  let
    exportLib = libName != "" and libName != "GLOBAL"

  var glue = ""
  if exportLib:
    glue.add SL & ".createTable(0.cint, " & $(arg.len) & ".cint)\n"

  for i in 0..arg.len-1:
    let n = arg[i]
    if n.node.kind != nnkSym:
      error("bindConst: arg[" & $i & "] need symbol not " & $n.node.kind)

    let exportedName = n.name

    if exportLib:
      glue.add "discard " & SL & ".pushString(\"" & exportedName & "\")\n"
      glue.add constructConst(SL, getImpl(n.node.symbol), $n.node)
      glue.add SL & ".setTable(-3)\n"
    else:
      glue.add constructConst(SL, getImpl(n.node.symbol), $n.node)
      glue.add SL & ".setGlobal(\"" & exportedName & "\")\n"

  if exportLib:
    glue.add SL & ".setGlobal(\"" & libName & "\")"

  result = parseCode(glue)

macro bindConst*(arg: varargs[untyped]): stmt =
  result = genProxyMacro(arg, {nlbUseLib}, "Const")

# -----------------------------------------------------------------------
# ----------------------------- bindObject ------------------------------
# -----------------------------------------------------------------------

proc bindObjectConstructor(n, subject: NimNode, glueProc, procName, subjectName: string): string {.compileTime.} =
  if n.kind != nnkProcDef:
    error("bindFunction: " & procName & " is not a proc")

  let params = n[3]
  let retType = params[0]

  if subject.kind != retType.kind and $subject != $retType:
    error("object method need object type as first param")
    
  let argList = paramsToArgList(params)
  
  var glue = "proc " & glueProc & "(L: PState): cint {.cdecl.} =\n"
  glue.add "  var udata = cast[ptr $1](L.newUserData(sizeof($1)))\n" % [$subject]
  
  var glueParam = ""
  for i in 0..argList.len-1:
    glue.add "  let arg" & $i & " = " & constructArg(argList[i].mName, argList[i].mType, i + 1)
    glueParam.add "arg" & $i
    if i < argList.len-1: glueParam.add ", "
    
  let procCall = procName & "(" & glueParam & ")"
  glue.add "  udata[] = " & procCall & "\n"
  glue.add "  GC_ref(udata[])\n"
  glue.add "  L.getMetatable(luaL_$1)\n" % [subjectName]
  glue.add "  discard L.setMetatable(-2)\n"
  glue.add "  result = 1\n"
  result = glue

proc bindObjectSingleMethod(n, subject: NimNode, glueProc, procName, subjectName: string): string {.compileTime.} =
  if n.kind != nnkProcDef:
    error("bindFunction: " & procName & " is not a proc")

  let params = n[3]
  let retType = params[0]
  let argList = paramsToArgList(params)
  
  if argList.len == 0:
    error("invalid object method")
  
  if subject.kind != argList[0].mType.kind and not sameType(subject, argList[0].mType):
    error("object method need object type as first param")
  
  var glue = "proc " & glueProc & "(L: PState): cint {.cdecl.} =\n"
  glue.add "  var foo = L.check$1(1)\n" % subjectName
  glue.add genOvCallSingle(newProcElem(retType, argList), procName, "", {ovfUseObject, ovfUseRet})
  result = glue
  
proc bindObjectOverloadedMethod(ov, subject: NimNode, glueProc, procName, subjectName: string): string {.compileTime.} =
  var ovl = newSeq[ovProc]()
  
  for s in children(ov):
    let n = getImpl(s.symbol)
    if n.kind != nnkProcDef:
      error("bindObject: " & procName & " is not a proc")

    let params = n[3]
    let retType = params[0]
    let argList = paramsToArgList(params)

    if argList.len == 0: continue #not a valid object method
    if subject.kind != argList[0].mType.kind and not sameType(subject, argList[0].mType): continue
    ovl.addOvProc(retType, argList)
  
  var glue = "proc " & glueProc & "(L: PState): cint {.cdecl.} =\n"
  glue.add "  var foo = L.check$1(1)\n" % subjectName
  glue.add genOvCall(ovl, procName, {ovfUseObject, ovfUseRet})
  glue.add "  discard L.error(\"$1: invalid param count\")\n" % [procName]
  glue.add "  return 0\n"

  result = glue
  
proc bindObjectImpl*(SL: string, subject: NimNode, arg: openArray[elemTup]): NimNode {.compileTime.} =
  let subjectName = $subject & $objectCount
  var glue = "const\n"
  glue.add "  luaL_$1 = \"luaL_$1\"\n" % [subjectName]
  glue.add "proc check$1(L: PState, n: int): $2 =\n" % [subjectName, $subject]
  glue.add "  result = cast[ptr $1](L.checkUData(n.cint, luaL_$2))[]\n" % [$subject, subjectName]
  glue.add "discard $1.newMetatable(luaL_$2)\n" % [SL, subjectName]
  
  var regs = "var regs$1 = [\n" % [subjectName]
  
  for i in 0..arg.len-1:
    let n = arg[i]
    if n.node.kind notin {nnkSym, nnkClosedSymChoice}:
      error("bindObject: arg[" & $i & "] need symbol not " & $n.node.kind)

    let
      procName = getAccQuotedName(n.node, n.kind)
      glueProc = "nimLUAproxy" & $proxyCount
      exportedName = if n.name == "constructor": "new" else: n.name

    regs.add "  luaL_Reg(name: \"$1\", fn: $2),\n" % [exportedName, glueProc]
        
    if n.node.kind == nnkSym:
      if n.name == "constructor":
        glue.add bindObjectConstructor(getImpl(n.node.symbol), subject, glueProc, procName, subjectName)
      else:
        glue.add bindObjectSingleMethod(getImpl(n.node.symbol), subject, glueProc, procName, subjectName)
    else: #nnkClosedSymChoice
      glue.add bindObjectOverloadedMethod(n.node, subject, glueProc, procName, subjectName)
    
    inc proxyCount
    
  glue.add "proc $1_destructor(L: PState): cint {.cdecl.} =\n" % [subjectName]
  glue.add "  var foo = L.check$1(1)\n" % [subjectName]
  glue.add "  GC_unref(foo)\n"
  
  regs.add "  luaL_Reg(name: \"__gc\", fn: $1_destructor),\n" % [subjectName]
  regs.add "  luaL_Reg(name: nil, fn: nil)\n"
  regs.add "]\n"
  
  glue.add regs
  glue.add "$1.setFuncs(cast[ptr luaL_reg](addr(regs$2)), 0)\n" % [SL, subjectName]
  glue.add "$1.pushValue(-1)\n" % [SL]
  glue.add "$1.setField(-1, \"__index\")\n" % [SL]
  glue.add "$1.setGlobal(\"$2\")\n" % [SL, $subject]
  
  result = parseCode(glue)

macro bindObject*(arg: varargs[untyped]): stmt =
  result = genProxyMacro(arg, {nlbRegisterObject}, "Object")
  inc objectCount