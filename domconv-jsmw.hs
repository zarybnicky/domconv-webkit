-- DOM interface converter: a tool to convert Haskell files produced by
-- H/Direct into properly structured DOM wrapper

module Main where

import System.Environment (getArgs)
import System.Exit
import System.IO
import Control.Monad (unless)
import Data.Maybe (fromJust)
import Data.List (intercalate, nub, isSuffixOf)
import Data.Char (isSpace, toUpper)
import Language.Haskell.Pretty
import Language.Preprocessor.Cpphs
import BrownPLT.JavaScript
import qualified Language.Haskell.Syntax as H
import qualified Data.Map as M
import qualified OmgParser
import LexM (runLexM)
import Literal (IntegerLit(ILit), Literal(IntegerLit))
import qualified IDLSyn as I
import IDLUtils (getDef)
import BasicTypes (ParamDir(In))
import SplitBounds (parts, splitBegin, splitEnd)

main :: IO ()
main = do
  args <- getArgs
  case parseOptions args of
    Left s -> do
      hPutStrLn stderr $ "domconv: command line parse error " ++ s
      exitFailure
    Right opts -> procopts opts

procopts :: CpphsOptions -> IO ()
procopts opts = do
  let cppfiles = infiles opts
      (hsrc, inclfile) =
        case cppfiles of
          [] -> (getContents, "<stdin>")
          ["-"] -> (getContents, "<stdin>")
          (a:_) -> (openFile a ReadMode >>= hGetContents, a)
  let baseopt = [("boolean", "Bool")]
      optsb = opts {defines = defines opts ++ baseopt
                   ,boolopts = (boolopts opts) {pragma = True} }
  hsrc' <- hsrc
  hsrcpr <- runCpphs optsb inclfile hsrc'
  x <- runLexM [] inclfile hsrcpr OmgParser.parseIDL
  let showMod (I.Module i d) = do
        putStrLn $ "module" ++ show i
        mapM_ print d
      showMod _ = return ()
  putStrLn "{--"
  mapM_ showMod x
  putStrLn "--}"
  let prntmap = mkParentMap x
  let valmsg = valParentMap prntmap
  unless (null valmsg) $ do
    mapM_ (hPutStrLn stderr) valmsg
    exitWith (ExitFailure 2)
  let modst = DOMState {
         pm = prntmap
        ,imp = []
        ,ns = "Data.DOM." -- this will be the default namespace unless a pragma namespace is used.
        ,procmod = []
        ,convlog = []
      }
      modst' = domLoop modst x
  mapM_ (hPutStrLn stderr) (convlog modst')
  let splitmod = splitModule (head $ procmod modst')
  mapM_ putSplit splitmod


-- Retrieve a module name as a string from Module
modName :: H.Module -> String
modName m = read $ drop 1 $ dropWhile (not . isSpace) (show m)

-- Get a module namespace (all elements of name separated with dots except
-- the last one)
modNS :: String -> String
modNS mn = intercalate "." mnpts where
  mnpts = case reverse $ parts (== '.') mn of
    [] -> []
    [_] -> []
    (_:ps) -> reverse ps

-- Write a module surrounded by split begin/end comments
putSplit :: H.HsModule -> IO ()
putSplit mod@(H.HsModule _ modid _ _ _) = do
  putStrLn $ "\n" ++ splitBegin ++ "/" ++ modName modid ++ "\n"
  putStrLn $ prettyPrint mod
  putStrLn $ "\n" ++ splitEnd ++ "\n"

-- Split a proto-module created by domLoop. All class, data, and instance definitions
-- remain in the "head" class. All methods are grouped by their `this' argument
-- context and placed into modules with the name of that context (first character removed).
-- All modules get the same imports that the "head" module has plus the "head" module itself.
splitModule :: H.HsModule -> [H.HsModule]
splitModule (H.HsModule _ modid _ imps decls) = headmod : submods where
  headns = modNS $ modName modid
  headmod = H.HsModule nullLoc modid headexp imps headdecls
  headdecls = datas ++ classes ++ instances
  headexp = Just $ map (mkEIdent . declname) (datas ++ classes)
  datas = filter datadecl decls
  datadecl H.HsDataDecl{} = True
  datadecl H.HsNewTypeDecl{} = True
  datadecl _ = False
  classes = filter classdecl decls
  classdecl H.HsClassDecl{} = True
  classdecl _ = False
  instances = filter instdecl decls
  instdecl H.HsInstDecl{} = True
  instdecl _ = False
  declname (H.HsDataDecl _ _ (H.HsIdent s) _ _ _) = s
  declname (H.HsNewTypeDecl _ _ (H.HsIdent s) _ _ _) = s
  declname (H.HsClassDecl _ _ (H.HsIdent s) _ _) = s
  declname (H.HsTypeSig _ [H.HsIdent s] _) = s
  declname (H.HsFunBind [H.HsMatch _ (H.HsIdent s) _ _ _]) = s
  declname _ = ""
  mtsigs = filter methtsig (reverse decls)
  methtsig H.HsTypeSig{} = True
  methtsig (H.HsFunBind _) = True
  methtsig _ = False
  corrn = drop 1 . dropWhile (/= '|')
  methcorrn (H.HsTypeSig x [H.HsIdent s] y) = H.HsTypeSig x [H.HsIdent (corrn s)] y
  methcorrn (H.HsFunBind [H.HsMatch x (H.HsIdent s) y z t]) =
    H.HsFunBind [H.HsMatch x (H.HsIdent (corrn s)) y z t]
  methcorrn z = z
  methassoc meth =
    let i = ns ++ takeWhile (/= '|') (declname meth)
        ns = case headns of
          "" -> ""
          mns -> mns ++ "."
    in (i, methcorrn meth)
  methmap = mkmethmap M.empty (map methassoc mtsigs)
  mkmethmap m [] = m
  mkmethmap m ((i, meth) : ims) = mkmethmap addmeth ims where
    addmeth = case M.lookup i m of
      Nothing -> M.insert i [meth] m
      (Just meths) -> M.insert i (meth : meths) m
  submods = M.elems $ M.mapWithKey mksubmod methmap
  mksubmod iid smdecls =
    H.HsModule nullLoc (H.Module iid) (Just subexp)
               (mkModImport modid : (imps ++ docimp)) smdecls where
      subexp = map mkEIdent $ nub $ filter (not . isSuffixOf "'") $ map declname smdecls
      docimp = case "createElement" `elem` map declname smdecls of
        True -> []
        _ -> [(mkModImport (H.Module docmod))
               {H.importSpecs = Just (False, [H.HsIVar $ H.HsIdent "createElement"])}] where
          docmod = intercalate "." $ reverse ("Document" : tail (reverse $ parts (== '.') iid))


-- Loop through the list of toplevel parse results (modules, pragmas).
-- Pragmas modify state, modules don't.
domLoop :: DOMState -> [I.Defn] -> DOMState
domLoop st [] = st
domLoop st (def : defs) = case def of
  I.Pragma prgm -> domLoop (prgm2State st (dropWhile isSpace prgm)) defs
  I.Module _ moddef ->
    let prmod = mod2mod st (I.Module id' moddef)
        modn = ns st ++ renameMod (intercalate "." $ reverse $ parts ( == '.') (getDef def))
        id' = I.Id modn
        imp' = modn : imp st
        modl = prmod : procmod st in
    domLoop st {procmod = modl, imp = imp'} defs
  z ->
    let logmsg = "Expected a Module or a Pragma; found " ++ show z in
    domLoop st {convlog = convlog st ++ [logmsg]} defs

-- Modify DOMState based on a pragma encountered
prgm2State :: DOMState -> String -> DOMState
prgm2State st ('n':'a':'m':'e':'s':'p':'a':'c':'e':nns) =
  let nnsst = read (dropWhile isSpace nns)
      dot = if null nnsst then "" else "." in
  st {ns = nnsst ++ dot}
prgm2State st upgm =
  let logmsg = "Unknown pragma " ++ upgm in
  st {convlog = convlog st ++ [logmsg]}

-- Validate a map of interface inheritance. Any "Left" parent identifier
-- causes a log message to be produced. It is also checked that an interface
-- does not have itself as a parent. Circular inheritance is not checked.
valParentMap :: M.Map String [Either String String] -> [String]
valParentMap = concat . M.elems . M.mapWithKey lefts where
  lefts intf = concatMap (leftmsg intf)
  leftmsg _ (Right _) = []
  leftmsg intf (Left p) = ["Interface " ++ intf ++ " has " ++ p ++ " as a parent, but " ++
                           p ++ " is not defined anywhere"]

-- Prepare a complete map of interfaces inheritance. All ancestors
-- must be defined in the IDL module being processed plus in other
-- modules it includes.
mkParentMap :: [I.Defn] -> M.Map String [Either String String]
mkParentMap defns = m2 where
  allintfs = nub $ concatMap getintfs defns
  getintfs (I.Module _ moddefs) = filter intfOnly moddefs
  getintfs _ = []
  m1 = M.fromList $ zip (map getDef allintfs) allintfs
  m2 = M.fromList (map getparents allintfs)
  getparents i@(I.Interface _ supers _ _ _) = (getDef i, concatMap parent supers)
  parent pidf = if pidf `M.member` m1
    then Right pidf : snd (getparents (fromJust $ M.lookup pidf m1))
    else [Left pidf]

-- Fake source location
nullLoc :: H.SrcLoc
nullLoc = H.SrcLoc {H.srcFilename = "", H.srcLine = 0, H.srcColumn = 0}
-- A list of single-letter formal argument names (max. 26)

azList :: [String]
azList = map (: []) ['a' .. 'z']

azHIList :: [H.HsName]
azHIList = map H.HsIdent azList

-- Rename a module. First character of module name is uppercased. Each
-- underscore followed by a character causes that character uppercased.
renameMod :: String -> String
renameMod "" = ""
renameMod (m:odule) = toUpper m : renameMod' odule where
  renameMod' "" = ""
  renameMod' ('_':o:dule) = '.' : toUpper o : renameMod' dule
  renameMod' ('.':o:dule) = '.' : toUpper o : renameMod' dule
  renameMod' (o:dule) = o : renameMod' dule

-- Module converter mutable state (kind of)
data DOMState = DOMState {
   pm :: M.Map String [Either String String] -- inheritance map
  ,imp :: [String]                           -- import list
  ,ns :: String                              -- output module namespace (#pragma namespace)
  ,procmod :: [H.HsModule]                   -- modules already processed
  ,convlog :: [String]                       -- conversion messages
} deriving (Show)


-- Helpers to produce class and datatype identifiers out of DOM identifiers
classFor, typeFor :: String -> String
classFor s = "C" ++ s
typeFor  s = "T" ++ s

-- Convert an IDL module definition into Haskell module syntax
mod2mod :: DOMState -> I.Defn -> H.HsModule
mod2mod st md@(I.Module _ moddefs) =
  H.HsModule nullLoc (H.Module modid') (Just []) imps decls where
    modlst = ["Control.Monad"
             ,"BrownPLT.JavaScript"
             ,"Data.DOM.WBTypes"]
    modid' = renameMod $ getDef md
    imps = map (mkModImport . H.Module) (modlst ++ imp st)
    intfs = filter intfOnly moddefs
    decls = types ++ classes ++ instances ++ methods ++ attrs ++ makers
    makers  = concatMap intf2maker intfs
    classes = concatMap intf2class intfs
    methods = concatMap intf2meth intfs
    types = concatMap intf2type intfs
    attrs = concatMap intf2attr intfs
    instances = concatMap (intf2inst $ pm st) intfs
mod2mod _ z = error $ "Input of mod2mod should be a Module but is " ++ show z

-- Create a module import declaration
mkModImport :: H.Module -> H.HsImportDecl
mkModImport s = H.HsImportDecl {H.importLoc = nullLoc
                               ,H.importQualified = False
                               ,H.importModule = s
                               ,H.importAs = Nothing
                               ,H.importSpecs = Nothing}

-- For each interface, locate it in the inheritance map,
-- and produce instance declarations for the corresponding datatype.
intf2inst :: M.Map String [Either String String] -> I.Defn -> [H.HsDecl]
intf2inst pm intf@I.Interface{} = self : parents where
  sid = getDef intf
  self = mkInstDecl sid sid
  parents = case M.lookup sid pm of
    Nothing -> []
    Just ess -> map (flip mkInstDecl sid . either id id) ess
intf2inst _ _ = []

-- For each interface found, define a newtype with the same name
intf2type :: I.Defn -> [H.HsDecl]
intf2type intf@I.Interface{} =
  let typename = H.HsIdent (typeFor $ getDef intf) in
  [H.HsDataDecl nullLoc [] typename []
    [H.HsConDecl nullLoc typename []] []]
intf2type _ = []

-- Convert an Interface specification into a class specification
intf2class :: I.Defn -> [H.HsDecl]
intf2class intf@(I.Interface _ supers _ _ _) =
  [H.HsClassDecl nullLoc sups (H.HsIdent (classFor $ getDef intf)) (take 1 azHIList) []] where
    sups = map name2ctxt supers
intf2class _ = []

-- Convert a name to a type context assertion (assume single parameter class)
name2ctxt :: String -> (H.HsQName, [H.HsType])
name2ctxt name = (mkUIdent $ classFor name, [H.HsTyVar $ head azHIList])

-- A helper function to produce an unqualified identifier
mkUIdent, mkSymbol :: String -> H.HsQName
mkUIdent = H.UnQual . H.HsIdent
mkSymbol = H.UnQual . H.HsSymbol

-- A filter to select only operations (methods)
opsOnly :: I.Defn -> Bool
opsOnly I.Operation{} = True
opsOnly _ = False

-- A filter to select only attributes
attrOnly :: I.Defn -> Bool
attrOnly I.Attribute{} = True
attrOnly _ = False

-- A filter to select only interfaces (classes)
intfOnly :: I.Defn -> Bool
intfOnly I.Interface{} = True
intfOnly _ = False

-- A filter to select only constant definitions
constOnly :: I.Defn -> Bool
constOnly I.Constant{} = True
constOnly _ = False

-- Collect all operations defined in an interface
collectOps :: I.Defn -> [I.Defn]
collectOps (I.Interface _ _ cldefs _ _) = filter opsOnly cldefs
collectOps _ = []

-- Collect all constants defined in an interface
collectConst :: I.Defn -> [I.Defn]
collectConst (I.Interface _ _ cldefs _ _) = filter constOnly cldefs
collectConst _ = []

-- Collect all attributes defined in an interface
collectAttrs :: I.Defn -> [I.Defn]
collectAttrs (I.Interface _ _ cldefs _ _) = filter attrOnly cldefs
collectAttrs _ = []

-- Declare an instance (very simple case, no context, no methods only one class parameter)
mkInstDecl :: String -> String -> H.HsDecl
mkInstDecl clname typename =
  H.HsInstDecl nullLoc [] (mkUIdent $ classFor clname) [mkTIdent $ typeFor typename] []

-- For certain interfaces (ancestors of HTMLElement), special maker functions
-- are introduced to simplify creation of the formers.
intf2maker :: I.Defn -> [H.HsDecl]
intf2maker (I.Interface (I.Id iid) _ _ _ _) =
  case tagFor iid of
    "" -> []
    tag -> [mktsig, mkimpl] where
      mkimpl =
        let defmaker = iid ++ "|mk" ++ renameMod tag
            crelv = mkVar "createElement"
            exprv = mkVar "StringLit"
            tags  = H.HsLit (H.HsString tag)
            tagv  = H.HsApp (H.HsApp exprv tags) tags
            rhs = H.HsUnGuardedRhs (H.HsApp crelv $ H.HsParen tagv)
            match = H.HsMatch nullLoc (H.HsIdent defmaker) [] rhs [] in
        H.HsFunBind [match]
      mktsig =
        let monadtv = mkTIdent "mn"
            exprtv = mkTIdent "Expression"
            defmaker = iid ++ "|mk" ++ renameMod tag
            parms = [H.HsIdent "a"]
            actx = (mkUIdent (classFor "HTMLDocument"),[mkTIdent "a"])
            monadctx = (mkUIdent "Monad",[monadtv])
            tpsig = mkTsig (map (H.HsTyApp exprtv . H.HsTyVar) parms)
                           (H.HsTyApp monadtv $ H.HsTyApp exprtv (mkTIdent (typeFor iid)))
            retts = H.HsQualType [monadctx, actx] tpsig in
        H.HsTypeSig nullLoc [H.HsIdent defmaker] retts
intf2maker _ = []

-- Tag values corresponding to certain HTML element interfaces
tagFor :: String -> String
tagFor "HTMLButtonElement" = "button"
tagFor "HTMLDivElement" = "div"
tagFor "HTMLImageElement" = "img"
tagFor "HTMLAppletElement" = "applet"
tagFor "HTMLFontElement" = "font"
tagFor "HTMLFormElement" = "form"
tagFor "HTMLFrameElement" = "frame"
tagFor "HTMLInputElement" = "input"
tagFor "HTMLObjectElement" = "object"
tagFor "HTMLParagraphElement" = "p"
tagFor "HTMLParamElement" = "param"
tagFor "HTMLPreElement" = "pre"
tagFor "HTMLScriptElement" = "script"
tagFor "HTMLTableCellElement" = "td"
tagFor "HTMLTableColElement" = "col"
tagFor "HTMLTableElement" = "table"
tagFor "HTMLTableRowElement" = "tr"
tagFor "HTMLTextAreaElement" = "textarea"
tagFor "HTMLBRElement" = "br"
tagFor "HTMLHRElement" = "hr"
tagFor "HTMLLIElement" = "li"
tagFor "HTMLDListElement" = "dl"
tagFor "HTMLOListElement" = "ol"
tagFor "HTMLUListElement" = "ul"
tagFor _ = ""

-- Attributes are represented by methods with proper type signatures.
-- These methods are wrappers around type-neutral unsafe get/set property
-- functions.
intf2attr :: I.Defn -> [H.HsDecl]
intf2attr intf@(I.Interface (I.Id iid) _ _ _ _) =
  concatMap mkattr $ collectAttrs intf where
    mkattr (I.Attribute [] _ _ _ _) = []
    mkattr (I.Attribute [I.Id iat] False tat _ _) = mksetter iid iat tat ++ mkgetter iid iat tat
    mkattr (I.Attribute [I.Id iat] True  tat _ _) = mkgetter iid iat tat
    mkattr (I.Attribute (iatt:iats) b tat _ _) =
      mkattr (I.Attribute [iatt] b tat [] []) ++ mkattr (I.Attribute iats b tat [] [])
    mksetter iid iat tat = [stsig iid iat tat, simpl iid iat]
    monadtv = mkTIdent "mn"
    exprtv = mkTIdent "Expression"
    monadctx = (mkUIdent "Monad",[monadtv])
    simpl iid iat =
      let defset = iid ++ "|set'" ++ iat
          unssetp = mkVar "setjsProperty"
          propnam = H.HsLit (H.HsString iat)
          rhs = H.HsUnGuardedRhs (H.HsApp unssetp propnam)
          match = H.HsMatch nullLoc (H.HsIdent defset) [] rhs [] in
      H.HsFunBind [match]
    stsig iid iat tat =
      let ityp = I.TyName iid Nothing
          defset = iid ++ "|set'" ++ iat
          parm = [I.Param I.Required (I.Id "val") tat [I.Mode In] []]
          parms = map (fst . tyParm) parm ++ [H.HsIdent "zz"]
          contxt = concatMap (snd . tyParm) parm ++ ctxRet ityp
          tpsig = mkTsig (map (H.HsTyApp exprtv . H.HsTyVar) parms)
                         (H.HsTyApp monadtv $ H.HsTyApp exprtv (tyRet ityp))
          retts = H.HsQualType (monadctx : contxt) tpsig in
      H.HsTypeSig nullLoc [H.HsIdent defset] retts
    mkgetter iid iat tat = [gtsig iid iat tat, gimpl iid iat tat, gtcnc iid iat tat, eqcnc iid iat]
    gimpl iid iat tat =
      let defget = iid ++ "|get'" ++ iat
          parm = H.HsPVar $ H.HsIdent "thisp"
          rhs = H.HsUnGuardedRhs $ mkGetter iat parm (tyRet tat)
          match = H.HsMatch nullLoc (H.HsIdent defget) [parm] rhs [] in
      H.HsFunBind [match]
    gtsig iid iat tat =
      let defget = iid ++ "|get'" ++ iat
          parms = [H.HsIdent "this"]
          thisctx = (mkUIdent (classFor iid),[mkTIdent "this"])
          tpsig = mkTsig (map (H.HsTyApp exprtv . H.HsTyVar) parms)
                         (H.HsTyApp monadtv $ H.HsTyApp exprtv (tyRet tat))
          retts = H.HsQualType (monadctx : thisctx : ctxRet tat) tpsig in
      H.HsTypeSig nullLoc [H.HsIdent defget] retts
    gtcnc iid iat tat =
      let defcnc = iid ++ "|getm'" ++ iat
          parms = [H.HsIdent "this"]
          thisctx = (mkUIdent (classFor iid),[mkTIdent "this"])
          tpsig = mkTsig (map (H.HsTyApp exprtv . H.HsTyVar) parms)
                         (H.HsTyApp monadtv $ H.HsTyApp exprtv (cnRet tat))
          retts = H.HsQualType [monadctx, thisctx] tpsig in
      H.HsTypeSig nullLoc [H.HsIdent defcnc] retts
    eqcnc iid iat =
      let defcnc = iid ++ "|getm'" ++ iat
          defget = "get'" ++ iat
          rhs = H.HsUnGuardedRhs (mkVar defget)
          match = H.HsMatch nullLoc (H.HsIdent defcnc) [] rhs [] in
      H.HsFunBind [match]
intf2attr _ = []

-- Create a Javascript body for a getter. Template for a getter is:
-- get'prop this = do
--   let et = undefined :: zz
--       r = DotRef et (this /\ et) (Id et "propname")
--   return r
-- where zz is a type variable or type name of the method return type.
mkGetter :: String -> H.HsPat -> H.HsType -> H.HsExp
mkGetter prop _ rett = H.HsDo [let1, let2, ret] where
  let1 = H.HsLetStmt [
           H.HsFunBind [
             H.HsMatch nullLoc
                       (H.HsIdent "et")
                       []
                       (H.HsUnGuardedRhs $ H.HsExpTypeSig nullLoc
                                                          (mkVar "undefined")
                                                          (H.HsQualType [] rett))
                       []
            ]
          ]
  let2 = H.HsLetStmt [
           H.HsFunBind [
             H.HsMatch nullLoc
                       (H.HsIdent "r")
                       []
                       (H.HsUnGuardedRhs $ H.HsApp (
                                             H.HsApp (
                                               H.HsApp (mkVar "DotRef")
                                                       (mkVar "et"))
                                               (H.HsParen $
                                                  H.HsInfixApp (mkVar "thisp")
                                                               (H.HsQVarOp $ mkSymbol "/\\")
                                                               (mkVar "et")))
                                             (H.HsParen $
                                                H.HsApp (
                                                  H.HsApp (mkVar "Id")
                                                          (mkVar "et"))
                                                  (H.HsLit $ H.HsString prop)))
                       []
             ]
           ]
  ret = H.HsQualifier $
          H.HsApp (mkVar "return") (mkVar "r")

-- Methods are lifted to top level. Declared argument types are converted
-- into type constraints unless they are of primitive types. First argument
-- always gets a type of the interface where the method is declared.
-- Only `In' parameters are supported at this time. The "this" argument
-- goes last to make monadic composition of actions easier.
intf2meth :: I.Defn -> [H.HsDecl]
intf2meth intf@I.Interface{} =
  concatMap mkmeth (collectOps intf) ++
  concatMap mkconst (collectConst intf) where
    getDefJs op@(I.Operation _ _ _ _ mbctx _) = case mbctx of
      Nothing -> getDef op
      Just [] -> getDef op
      Just (s:_) -> s
    mkconst (I.Constant (I.Id cid) _ _ (I.Lit (IntegerLit (ILit _ val)))) =
      let defcn = getDef intf ++ "|c" ++ cid
          match = H.HsMatch nullLoc (H.HsIdent defcn) [] crhs []
          crhs = H.HsUnGuardedRhs (H.HsLit (H.HsInt val))
      in  [H.HsFunBind [match]]
    mkmeth op = tsig op : timpl op
    tsig op@(I.Operation (I.FunId _ _ parm) _ optype _ _ _) =
      let monadtv = mkTIdent "mn"
          exprtv = mkTIdent "Expression"
          defop = getDef intf ++ "|" ++ getDef op
          parms = map (fst . tyParm) parm ++ [H.HsIdent "this"]
          contxt = concatMap (snd . tyParm) parm ++ ctxRet optype
          monadctx = (mkUIdent "Monad",[monadtv])
          thisctx = (mkUIdent (classFor $ getDef intf),[mkTIdent "this"])
          tpsig = mkTsig (map (H.HsTyApp exprtv . H.HsTyVar) parms)
                         (H.HsTyApp monadtv $ H.HsTyApp exprtv (tyRet optype))
          retts = H.HsQualType (monadctx : thisctx : contxt) tpsig in
      H.HsTypeSig nullLoc [H.HsIdent defop] retts
    timpl op@(I.Operation (I.FunId _ _ parm) _ optype _ _ _) =
      let defop = getDef intf ++ "|" ++ getDef op
          parms = map H.HsPVar (take (length parm) azHIList ++ [H.HsIdent "thisp"])
          rhs = H.HsUnGuardedRhs $ mkMethod (getDefJs op) parms (tyRet optype)
          match  = H.HsMatch nullLoc (H.HsIdent defop) parms rhs []
      in  [H.HsFunBind [match]]
intf2meth _ = []

-- Create a Javascript body for a method. Template for a method is:
-- method a1 ... an this = do
--   let et = undefined :: zz
--       r = DotRef et (this /\ et) (Id et "methodname")
--   return (CallExpr et r [a1 /\ et, ... an /\ et]
-- where zz is a type variable or type name of the method return type.
mkMethod :: String -> [H.HsPat] -> H.HsType -> H.HsExp
mkMethod meth args rett = H.HsDo [let1, let2, ret] where
  args' = init args
  cast ts (H.HsPVar (H.HsIdent hn)) =
    H.HsInfixApp (mkVar hn) (H.HsQVarOp $ mkSymbol "/\\") (mkVar ts)
  let1 = H.HsLetStmt [
           H.HsFunBind [
             H.HsMatch nullLoc
                       (H.HsIdent "et")
                       []
                       (H.HsUnGuardedRhs $ H.HsExpTypeSig nullLoc
                                                          (mkVar "undefined")
                                                          (H.HsQualType [] rett))
                       []
            ]
          ]
  let2 = H.HsLetStmt [
           H.HsFunBind [
             H.HsMatch nullLoc
                       (H.HsIdent "r")
                       []
                       (H.HsUnGuardedRhs $ H.HsApp (
                                             H.HsApp (
                                               H.HsApp (mkVar "DotRef")
                                                       (mkVar "et"))
                                               (H.HsParen $
                                                  H.HsInfixApp (mkVar "thisp")
                                                               (H.HsQVarOp $ mkSymbol "/\\")
                                                               (mkVar "et")))
                                             (H.HsParen $
                                                H.HsApp (
                                                  H.HsApp (mkVar "Id")
                                                          (mkVar "et"))
                                                  (H.HsLit $ H.HsString meth)))
                       []
             ]
           ]
  ret = H.HsQualifier $
          H.HsApp (mkVar "return")
                  (H.HsParen $
                     H.HsApp (
                       H.HsApp (
                         H.HsApp (mkVar "CallExpr")
                                 (mkVar "et"))
                         (mkVar "r"))
                       (H.HsList $ map (cast "et") args'))

-- Build a variable name
mkVar :: String -> H.HsExp
mkVar = H.HsVar . mkUIdent

-- Build a method's type signature
mkTsig :: [H.HsType] -> H.HsType -> H.HsType
mkTsig ps a = foldr H.HsTyFun a ps

-- A helper function to produce a type identifier
mkTIdent :: String -> H.HsType
mkTIdent = H.HsTyVar . H.HsIdent

-- A helper function to produce an export identifier.
-- Datas (Txxx) export all their members.
mkEIdent :: String -> H.HsExportSpec
mkEIdent name@(n:_)
  | n == 'T' = (H.HsEThingAll . H.UnQual . H.HsIdent) name
  | otherwise = (H.HsEVar . H.UnQual . H.HsIdent) name


-- Obtain a return type signature from a return type
tyRet :: I.Type -> H.HsType
tyRet (I.TyName c Nothing) = case asIs c of
  Nothing -> mkTIdent "zz"
  Just c' -> mkTIdent c'
tyRet (I.TyInteger _) = mkTIdent "Double"
tyRet (I.TyFloat _) = mkTIdent "Double"
tyRet (I.TyApply _ (I.TyInteger _)) = mkTIdent "Double"
tyRet  I.TyVoid  = H.HsTyTuple []
tyRet t = error $ "Return type " ++ show t

-- The same, for a concrete type
cnRet :: I.Type -> H.HsType
cnRet (I.TyName c Nothing) = case asIs c of
  Nothing -> mkTIdent ('T' : c)
  Just c' -> mkTIdent c'
cnRet z = tyRet z

-- Obtain a return type context (if any) from a return type
ctxRet :: I.Type -> [H.HsAsst]
ctxRet (I.TyName c Nothing) = case asIs c of
  Nothing -> [(mkUIdent $ classFor c, [mkTIdent "zz"])]
  Just _ -> []
ctxRet _ = []

-- Obtain a type signature from a parameter definition
tyParm :: I.Param -> (H.HsName, [H.HsAsst])
tyParm (I.Param I.Required (I.Id p) ptype [I.Mode In] _) =
  let hsidp = H.HsIdent p in
  case ptype of
    I.TyName c Nothing -> case asIs c of
      Just cc ->  (H.HsIdent cc, [])
      Nothing -> (hsidp, [(mkUIdent $ classFor c, [mkTIdent p])])
    I.TyInteger _ -> (H.HsIdent "Double",[])
    I.TyFloat _ -> (H.HsIdent "Double",[])
    I.TyApply _ (I.TyInteger _) -> (H.HsIdent "Double",[])
    t -> error $ "Param type " ++ show t
tyParm I.Param{} = error "Unsupported parameter attributes"

-- Some types pass through as is, other are class names
asIs :: String -> Maybe String
asIs "DOMString" = Just "String"
asIs "Bool"      = Just "Bool"
asIs "Int"       = Just "Double"
asIs _ = Nothing


