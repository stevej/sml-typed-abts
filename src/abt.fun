functor Abt
  (structure Symbol : SYMBOL
   structure Variable : SYMBOL
   structure Metavariable : SYMBOL
   structure Operator : OPERATOR
   structure Metacontext : METACONTEXT
     where type metavariable = Metavariable.t
     where type valence = Operator.Arity.Valence.t) : ABT =
struct

  structure Symbol = Symbol
    and Variable = Variable
    and Metavariable = Metavariable
    and Operator = Operator
    and Arity = Operator.Arity
    and Metacontext = Metacontext

  structure Sort = Arity.Sort and Valence = Arity.Valence
  structure Spine = Valence.Spine

  type symbol = Symbol.t
  type variable = Variable.t
  type metavariable = Metavariable.t
  type metacontext = Metacontext.t

  type operator = symbol Operator.t
  type sort = Sort.t
  type valence = Valence.t
  type coord = Coord.t

  type 'a spine = 'a Spine.t

  structure LN =
  struct
    datatype 'a t =
        FREE of 'a
      | BOUND of coord

    functor Eq (I : EQ) : EQ =
    struct
      type t = I.t t
      fun eq (FREE v, FREE v') = I.eq (v, v')
        | eq (BOUND i, BOUND j) = Coord.Eq.eq (i, j)
        | eq _ = false
    end

    type symbol = symbol t
    type operator = symbol Operator.t
    type variable = variable t

    exception UnexpectedBoundName of coord

    fun getFree (FREE v) = v
      | getFree (BOUND i) = raise UnexpectedBoundName i

    structure Functor : FUNCTOR =
    struct
      type 'a t = 'a t
      fun map f (FREE v) = FREE (f v)
        | map f (BOUND i) = BOUND i
    end

    structure Monad : MONAD =
    struct
      type 'a t = 'a t
      fun pure v = FREE v
      fun bind f (FREE v) = f v
        | bind f (BOUND i) = BOUND i
    end
  end

  datatype abt =
      V of LN.variable * sort
    | APP of LN.operator * btm spine
    | META_APP of metavariable * (LN.symbol * sort) spine * abt spine
  and btm = ABS of (symbol * sort) spine * (variable * sort) spine * abt

  (* Patterns for abstract binding trees. *)
  datatype 'tm view =
      ` of variable
    | $ of operator * 'tm bview spine
    | $# of metavariable * (symbol spine * 'tm spine)

  and 'tm bview =
     \ of (symbol spine * variable spine) * 'tm

  infixr 5 \
  infix 5 $ $#

  functor Union (Eq : EQ) =
  struct
    fun elem (X, x) = List.exists (fn y => Eq.eq (x, y)) X
    fun union ([], Y) = Y
      | union (x :: X, Y) = if elem (Y, x) then union (X, Y) else x :: (union (X,  Y))
  end

  functor AnnotatedEq (Eq : EQ) =
  struct
    type t = Eq.t * sort
    fun eq ((a, sigma), (b, tau)) = Eq.eq (a, b)
  end

  fun assert msg b =
    if b then () else raise Fail msg

  fun assertSortEq (sigma, tau) =
    assert
      ("expected " ^ Sort.Show.toString sigma ^ " == " ^ Sort.Show.toString tau)
      (Sort.Eq.eq (sigma, tau))

  fun assertValenceEq (v1, v2) =
    assert
      ("expected " ^ Valence.Show.toString v1 ^ " == " ^ Valence.Show.toString v2)
      (Valence.Eq.eq (v1, v2))

  local
    structure VS = Union (AnnotatedEq (Symbol.Eq))
    structure VU = Union (AnnotatedEq (Variable.Eq))
  in
    fun freeVariables M =
      let
        fun go R (V (LN.FREE v, sigma)) = VU.union ([(v, sigma)], R)
          | go R (APP (theta, Es)) =
              Spine.Foldable.foldr VU.union R (Spine.Functor.map (go' []) Es)
          | go R (META_APP (m, us, Ms)) =
              Spine.Foldable.foldr VU.union R (Spine.Functor.map (go []) Ms)
          | go R _ = R
        and go' R (ABS (_, _, M)) = go R M
      in
        go [] M
      end

    fun freeSymbols M =
      let
        fun opFreeSymbols theta =
          let
            val Ypsilon = Operator.support theta
          in
            List.foldl (fn ((u, sigma), R) => ((LN.getFree u, sigma) :: R) handle _ => R) [] Ypsilon
          end
        fun go R (APP (theta, Es)) =
              VS.union (opFreeSymbols theta, Spine.Foldable.foldr VS.union R (Spine.Functor.map (go' []) Es))
          | go R (META_APP (m, us, Ms)) =
              VS.union
                (Spine.Foldable.foldr (fn ((u, sigma), X) => (LN.getFree u, sigma) :: X handle _ => X) [] us,
                 Spine.Foldable.foldr VS.union R (Spine.Functor.map (go []) Ms))
          | go R _ = R
        and go' R (ABS (us, _, M)) = go R M
      in
        go [] M
      end
  end

  fun subst (N, x) M =
    case M of
         V (LN.FREE y, sigma) => if Variable.Eq.eq (x, y) then N else M
       | V _ => M
       | APP (theta, Es) =>
           APP (theta, Spine.Functor.map (substBtm (N, x)) Es)
       | META_APP (m, us, Ms) =>
           META_APP (m, us, Spine.Functor.map (subst (N, x)) Ms)
  and substBtm (N, x) (ABS (us, xs, M)) =
    ABS (us, xs, subst (N, x) M)

  fun rename (v, u) =
    let
      fun go M =
        case M of
             V _ => M
           | APP (theta, Es) =>
             let
               fun rho u' = if Symbol.Eq.eq (u, u') then v else u'
               val theta' = Operator.Presheaf.map (LN.Functor.map rho) theta
             in
               APP (theta', Spine.Functor.map go' Es)
             end
           | META_APP (m, us, Ms) =>
               let
                 fun rho u' = if Symbol.Eq.eq (u, u') then v else u'
                 fun rho' (l, s) = (LN.Functor.map rho l, s)
               in
                 META_APP (m, Spine.Functor.map rho' us, Spine.Functor.map go Ms)
               end
      and go' (ABS (us, vs, M)) = ABS (us, vs, go M)
    in
      fn M =>
        if List.exists (fn (v', _) => Symbol.Eq.eq (v', v)) (freeSymbols M) then
          raise Fail "Renaming fails to preserve apartness"
        else
          go M
    end

  fun imprisonVariable (v, tau) (coord, M) =
    case M of
         V (LN.FREE v', sigma) =>
           if Variable.Eq.eq (v, v') then
             (assertSortEq (sigma, tau);
              V (LN.BOUND coord, sigma))
           else
             M
       | V _ => M
       | APP (theta, Es) =>
           APP (theta, Spine.Functor.map (fn N => imprisonVariableBtm (v, tau) (coord, N)) Es)
       | META_APP (m, us, Ms) =>
           META_APP (m, us, Spine.Functor.map (fn N => imprisonVariable (v, tau) (coord, N)) Ms)
  and imprisonVariableBtm (v, tau) (coord, ABS (us, xs, M)) =
    ABS (us, xs, imprisonVariable (v, tau) (Coord.shiftRight coord, M))

  fun imprisonSymbol (v, tau) (coord, M) =
    case M of
         V _ => M
       | APP (theta, Es) =>
         let
           fun rho v' = if Symbol.Eq.eq (v, v') then LN.BOUND coord else LN.FREE v'
           fun chk (LN.FREE v', tau') = if Symbol.Eq.eq (v, v') then assertSortEq (tau, tau') else ()
             | chk _ = ()
           val _ = List.app chk (Operator.support theta)
           val theta' = Operator.Presheaf.map (LN.Monad.bind rho) theta
         in
           APP (theta', Spine.Functor.map (fn E => imprisonSymbolBtm (v, tau) (coord, E)) Es)
         end
       | META_APP (m, us, Ms) =>
         let
           fun rho v' = if Symbol.Eq.eq (v, v') then LN.BOUND coord else LN.FREE v'
           fun rho' (l, s) = (LN.Monad.bind rho l, s)
           val vs = Spine.Functor.map rho' us
         in
           META_APP (m, vs, Spine.Functor.map (fn N => imprisonSymbol (v, tau) (coord, N)) Ms)
         end
  and imprisonSymbolBtm (v, tau) (coord, ABS (us, xs, M)) =
    ABS (us, xs, imprisonSymbol (v, tau) (Coord.shiftRight coord, M))


  fun liberateVariable v (coord, e) =
    case e of
         V (LN.FREE _, _) => e
       | V (LN.BOUND coord', sigma) =>
           if Coord.Eq.eq (coord, coord') then V (LN.FREE v, sigma) else e
       | APP (theta, es) =>
           APP (theta, Spine.Functor.map (fn e => liberateVariableBtm v (coord, e)) es)
       | META_APP (m, us, Ms) =>
           META_APP (m, us, Spine.Functor.map (fn e => liberateVariable v (coord, e)) Ms)
  and liberateVariableBtm v (coord, ABS (us, xs, M)) =
    ABS (us, xs, liberateVariable v (Coord.shiftRight coord, M))


  fun liberateSymbol v (coord, e) =
    case e of
         V _ => e
       | APP (theta, es) =>
         let
           fun rho (LN.BOUND coord') =
               if Coord.Eq.eq (coord, coord') then LN.FREE v else LN.BOUND coord'
             | rho v' = v'
           val theta' = Operator.Presheaf.map rho theta
         in
           APP (theta', Spine.Functor.map (fn e => liberateSymbolBtm v (coord, e)) es)
         end
       | META_APP (m, us, Ms) =>
         let
           fun rho (LN.BOUND coord') =
               if Coord.Eq.eq (coord, coord') then LN.FREE v else LN.BOUND coord'
             | rho v' = v'
           fun rho' (l, s) = (rho l, s)
           val vs = Spine.Functor.map rho' us
         in
           META_APP (m, vs, Spine.Functor.map (fn e => liberateSymbol v (coord, e)) Ms)
         end
  and liberateSymbolBtm v (coord, ABS (us, xs, M)) =
    ABS (us, xs, liberateSymbol v (Coord.shiftRight coord, M))

  local
    structure ShiftFunCat : CATEGORY =
    struct
      type ('a, 'b) hom = (coord * 'a -> 'b)
      fun id (_, x) = x
      fun comp (f, g) (coord, a) = f (coord, g (Coord.shiftDown coord, a))
    end

    structure ShiftFoldMap =
      CategoryFoldMap
        (structure C = ShiftFunCat
         structure F = Spine.Foldable)
  in
    fun imprisonVariables (vs, sorts) t =
      let
        val Gamma = Spine.Pair.zipEq (vs, sorts)
      in
        ShiftFoldMap.foldMap imprisonVariable Gamma (Coord.origin, t)
      end

    fun imprisonSymbols (vs, sorts) t =
      let
        val Upsilon = Spine.Pair.zipEq (vs, sorts)
      in
        ShiftFoldMap.foldMap imprisonSymbol Upsilon (Coord.origin, t)
      end

    fun liberateVariables vs t =
      ShiftFoldMap.foldMap liberateVariable vs (Coord.origin, t)

    fun liberateSymbols vs t =
      ShiftFoldMap.foldMap liberateSymbol vs (Coord.origin, t)
  end

  fun checkb Theta ((us, xs) \ M) ((ssorts, vsorts), sigma) =
    let
      val (_, tau) = infer Theta M
      val () = assertSortEq (sigma, tau)
    in
      ABS (Spine.Pair.zipEq (us, ssorts),
           Spine.Pair.zipEq (xs, vsorts),
           imprisonSymbols (us, ssorts) (imprisonVariables (xs, vsorts) M))
    end

  and infer Theta M =
    case M of
         V (x, tau) => (` (LN.getFree x), tau)
       | APP (theta, Es) =>
         let
           val (_, tau) = Operator.arity theta
           val theta' = Operator.Presheaf.map LN.getFree theta
           val Es' = Spine.Functor.map (#1 o inferb Theta) Es
         in
           (theta' $ Es', tau)
         end
       | META_APP (mv, us, Ms) =>
         let
           val (_, tau) = Metacontext.lookup Theta mv
           val us' = Spine.Functor.map (LN.getFree o #1) us
         in
           (mv $# (us', Ms), tau)
         end

  and check Theta M sigma =
    case M of
         `x => V (LN.FREE x, sigma)
       | theta $ Es =>
           let
             val (valences, tau)  = Operator.arity theta
             val () = assertSortEq (sigma, tau)
             val theta' = Operator.Presheaf.map LN.FREE theta
             val Es' =
               Spine.Pair.mapEq
                 (fn (E, valence) => checkb Theta E valence)
                 (Es, valences)
           in
             APP (theta', Es')
           end
       | mv $# (us, Ms) =>
           let
             val ((ssorts, vsorts), tau) = Metacontext.lookup Theta mv
             val () = assertSortEq (sigma, tau)
             val us' = Spine.Pair.zipEq (Spine.Functor.map LN.FREE us, ssorts)
             fun chkInf (M, tau) =
               let
                 val (_, tau') = infer Theta M
               in
                 assertSortEq (tau, tau'); M
               end
             val Ms' = Spine.Pair.mapEq chkInf (Ms, vsorts)
           in
             META_APP (mv, us', Ms')
           end

  and inferb Theta (ABS (Upsilon, Gamma, M)) =
    let
      val us = Spine.Functor.map (Symbol.clone o #1) Upsilon
      val xs = Spine.Functor.map (Variable.clone o #1) Gamma
      val M' = liberateSymbols us (liberateVariables xs M)
      val (_, tau) = infer Theta M'
      val valence = ((Spine.Functor.map #2 Upsilon, Spine.Functor.map #2 Gamma), tau)
    in
      ((us, xs) \ M',
       valence)
    end

  structure BFunctor =
  struct
    type 'a t = 'a bview
    fun map f ((us, xs) \ M) =
      (us, xs) \ f M
  end

  structure Eq : EQ =
  struct
    type t = abt
    structure LnVarEq = LN.Eq (Variable.Eq)
    structure LnSymEq = LN.Eq (Symbol.Eq)
    structure OpLnEq = Operator.Eq (LnSymEq)
    structure OpEq = Operator.Eq (Symbol.Eq)
    fun eq (V (v, _), V (v', _)) = LnVarEq.eq (v, v')
      | eq (APP (theta, es), APP (theta', es')) =
          OpLnEq.eq (theta, theta') andalso Spine.Pair.allEq eq' (es, es')
      | eq (META_APP (mv, us, es), META_APP (mv', us', es')) =
          Metavariable.Eq.eq (mv, mv')
            andalso Spine.Pair.allEq (fn ((x, _), (y, _)) => LnSymEq.eq (x,y)) (us, us')
            andalso Spine.Pair.allEq eq (es, es')
      | eq _ = false
    and eq' (ABS (_, _, e), ABS (_, _, e')) = eq (e, e')
  end
end
