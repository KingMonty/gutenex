defmodule Gutenex.OpenType.Positioning do
  alias Gutenex.OpenType.Parser
  require Logger


  # add two positions together, treat nils as zeroed structure
  # category std_width, kern, pos can be used to optimize PDF output
  defp addPos(p, nil), do: p
  defp addPos(nil, {a,b,c,d}), do: {:pos, a, b, c, d}
  defp addPos(p, {0,0,0,0}), do: p
  defp addPos({:std_width, a,b,c,d}, {0,0,g,0}), do: {:kern, a, b, c+g, d}
  defp addPos({:std_width, a,b,c,d}, {e,f,g,h}), do: {:pos, a+e, b+f, c+g, d+h}
  defp addPos({type, a,b,c,d}, {e,f,g,h}), do: {type, a+e, b+f, c+g, d+h}
  
  # ==============================================
    # GPOS glyph positioning
    # Used for kerning, optical alignment, diacratics, etc
    # if a lookup type is as-yet unsupported
    # simply passes through the input
  # ==============================================

  # type 9 - when 32-bit offsets are used for subtables
  def applyLookupGPOS({9, flag, offsets, table, mfs}, gdef, lookups, isRTL, {glyphs, pos, c, m}) do
    subtables = offsets
            |> Enum.map(fn x ->
            <<1::16, actual_type::16, off::32>> = binary_part(table, x, 8)
            {actual_type, Parser.subtable(table, x + off)}
              end)
    #for each subtable
    Enum.reduce(subtables, {glyphs, pos, c, m}, fn ({type, tbl}, input) -> applyLookupGPOS({type, flag, tbl, mfs}, gdef, lookups, isRTL, input) end)
  end

  # all other types
  def applyLookupGPOS({type, flag, offsets, table, mfs}, gdef, lookups, isRTL, {glyphs, pos, c, m}) do
    #for each subtable
    Enum.reduce(offsets, {glyphs, pos, c, m}, fn (offset, input) -> applyLookupGPOS({type, flag, Parser.subtable(table, offset), mfs}, gdef, lookups, isRTL, input) end)
  end

  #type 1 - single positioning
  def applyLookupGPOS({1, _flag, table, _mfs}, _gdef, _lookups, _isRTL, {glyphs, pos, c, m}) do
    <<fmt::16, covOff::16, valueFormat::16, rest::binary>> = table
    coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
    valSize = Parser.valueRecordSize(valueFormat)
    adjusted = case fmt do
    1 ->
      <<val::binary-size(valSize), _::binary>> = rest
      val = Parser.readPositioningValueRecord(valueFormat, val)
      Enum.map(glyphs, fn g ->
        coverloc = findCoverageIndex(coverage, g)
        if coverloc != nil, do: val, else: nil
      end)
    2 ->
      <<nVals::16, _::binary>> = rest
      recs = binary_part(rest, 16, nVals * valSize)
      values = for << <<val::binary-size(valSize)>> <- recs >>, do: Parser.readPositioningValueRecord(valueFormat, val)
      Enum.map(glyphs, fn g ->
        coverloc = findCoverageIndex(coverage, g)
        if coverloc != nil, do: Enum.at(values, coverloc), else: nil
      end)
    end
    positioning = Enum.zip(pos, adjusted) |> Enum.map(fn {v1, v2} -> addPos(v1,v2) end)
    {glyphs, positioning, c, m}
  end

  # type 2 - pair positioning (ie, kerning)
  def applyLookupGPOS({2, _flag, table, _mfs}, _gdef,_lookups, _isRTL, {glyphs, pos, c, m}) do
    <<fmt::16, covOff::16, record1::16, record2::16, rest::binary>> = table
    kerning = case fmt do
      1 ->
        # FMT 1 - identifies individual glyphs
        # pair set table
        <<nPairs::16, pairOff::binary-size(nPairs)-unit(16), _::binary>> = rest
        pairsetOffsets = for << <<x::16>> <- pairOff >>, do: x
        # coverage table
        coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
        # parse the pair sets
        pairSets = Enum.map(pairsetOffsets, fn off -> Parser.parsePairSet(table, off, record1, record2) end)
        applyKerning(coverage, pairSets, glyphs, [])
      2 ->
        #FMT 2
        # offset to classdef, offset to classdef
        # nClass1Records, nClass2Records
        <<class1Off::16, class2Off::16, nClass1Records::16, nClass2Records::16, records::binary>> = rest

        #read in the class definitions
        class1 = Parser.parseGlyphClass(Parser.subtable(table, class1Off))
        class2 = Parser.parseGlyphClass(Parser.subtable(table, class2Off))
        # fmt==1, startglyph, nglyphs, array of ints (each int is a class)
        # fmt==2, nRanges, {startGlyph, endGlyph, class}

        #read in the actual positioning pairs
        sizeA = Parser.valueRecordSize(record1)
        sizeB = Parser.valueRecordSize(record2)
        class2size = sizeA + sizeB
        class1size = nClass2Records * class2size
        c1recs = binary_part(records, 0, nClass1Records * class1size)
        c1Recs = for << <<c2recs::binary-size(class1size)>> <- c1recs >>, do: c2recs
        pairSets = Enum.map(c1Recs, fn c2recs ->
          c2Recs = for << <<c2Rec::binary-size(class2size)>> <- c2recs>>, do: c2Rec
          c2Recs
          |> Enum.map(fn c2Rec -> for << <<v1::binary-size(sizeA), v2::binary-size(sizeB)>> <- c2Rec >>, do: {v1, v2} end)
          |> Enum.map(fn [{v1, v2}] -> {Parser.readPositioningValueRecord(record1, v1), Parser.readPositioningValueRecord(record2, v2)} end)
        end)

        #apply the kerning
        #classify both glyphs
        #get pairSet[c1][c2]
        #position
        applyKerning2(class1, class2, pairSets, glyphs, [])
    end
    positioning = Enum.zip(pos, kerning) |> Enum.map(fn {v1, v2} -> addPos(v1,v2) end)
    {glyphs, positioning, c, m}
  end

  # type 3 - cursive positioning
  def applyLookupGPOS({3, flag, table, mfs}, gdef, _lookups, isRTL, {glyphs, pos, c, m}) do
    <<_fmt::16, coverageOff::16, nAnchorPairs::16, nrecs::binary-size(nAnchorPairs)-unit(32), _::binary>> = table
    coverage = Parser.parseCoverage(Parser.subtable(table, coverageOff))
    records = for << <<entryAnchor::16, exitAnchor::16>> <- nrecs >>, do: {entryAnchor, exitAnchor}
    anchorPairs = records
                  |> Enum.map(fn {entryAnchor, exitAnchor} ->
                    entryAnchor = if entryAnchor != 0, do: Parser.parseAnchor(Parser.subtable(table, entryAnchor)), else: nil
                    exitAnchor = if exitAnchor != 0, do: Parser.parseAnchor(Parser.subtable(table, exitAnchor)), else: nil
                    {entryAnchor, exitAnchor}
                  end)

    # align entry/exit points
    {p, d} = applyCursive(coverage, anchorPairs, flag, mfs, gdef, isRTL, glyphs, pos, [], [])
    #Logger.debug "CURSIVE #{inspect glyphs} #{inspect d}"
    cdeltas = c
          |> Enum.with_index
          |> Enum.map(fn {v, i} -> if v != 0, do: v, else: Enum.at(d, i) end)
    {glyphs, p, cdeltas, m}
  end

  # type 4 - mark-to-base positioning
  def applyLookupGPOS({4, flag, table, mfs}, gdef,_lookups, _isRTL, {glyphs, pos, c, m}) do
    <<_fmt::16, markCoverageOff::16, baseCoverageOff::16, nClasses::16, 
    markArrayOffset::16, baseArrayOffset::16, _::binary>> = table
    
    # coverage definitions
    markCoverage = Parser.parseCoverage(Parser.subtable(table, markCoverageOff))
    baseCoverage = Parser.parseCoverage(Parser.subtable(table, baseCoverageOff))

    # baseArray table
    baseTbl = Parser.subtable(table, baseArrayOffset)
    <<nRecs::16, records::binary>> = baseTbl
    # 2 bytes per class
    recordSize = nClasses * 2
    records = binary_part(records, 0, nRecs * recordSize)
    records = for << <<record::binary-size(recordSize)>> <- records >>, do: record
    # each record is array of offsets
    baseArray = records
              |> Enum.map(fn r -> for << <<offset::16>> <- r>>, do: offset end)
              |> Enum.map(&Enum.map(&1, fn o -> 
                                Parser.parseAnchor(Parser.subtable(baseTbl, o)) end) 
                        )

    # markArray table
    markArrayTbl = Parser.subtable(table, markArrayOffset)
    markArray = Parser.parseMarkArray(markArrayTbl)

    # mark attachment classes
    adjusted = applyMarkToBase(markCoverage, baseCoverage, 
                               baseArray, markArray, 
                               # skip flags and GDEF info
                               flag, mfs, gdef, 
                               #prev and next details
                               [hd(glyphs)], tl(glyphs), pos, [nil])

    # apply the adjustments to positioning
    positioning = Enum.zip(pos, adjusted) |> Enum.map(fn {v1, v2} -> addPos(v1,v2) end)
    {glyphs, positioning, c, m}
  end

  # type 5 - mark to ligature positioning
  def applyLookupGPOS({5, _flag, table, _mfs}, _gdef,_lookups, _isRTL, {glyphs, pos, c, m}) do
    # same as format 4, except "base" is a ligature with (possibly) multiple anchors
    <<_fmt::16, markCoverageOff::16, baseCoverageOff::16, _nClasses::16, 
    markArrayOffset::16, _baseArrayOffset::16, _::binary>> = table

    _markCoverage = Parser.parseCoverage(Parser.subtable(table, markCoverageOff))
    _baseCoverage = Parser.parseCoverage(Parser.subtable(table, baseCoverageOff))

    markArrayTbl = Parser.subtable(table, markArrayOffset)
    _markArray = Parser.parseMarkArray(markArrayTbl)

    Logger.debug "GPOS 5 - mark to ligature"
    {glyphs, pos, c, m}
  end

  # type 6 - mark to mark positioning
  def applyLookupGPOS({6, flag, table, mfs}, gdef,_lookups, _isRTL, {glyphs, pos, c, m}) do
    # same as format 4, except "base" is another mark
    <<_fmt::16, markCoverageOff::16, baseCoverageOff::16, nClasses::16, 
    markArrayOffset::16, baseArrayOffset::16, _::binary>> = table
    
    markCoverage = Parser.parseCoverage(Parser.subtable(table, markCoverageOff))
    baseCoverage = Parser.parseCoverage(Parser.subtable(table, baseCoverageOff))
    # baseArray table
    baseTbl = Parser.subtable(table, baseArrayOffset)
    <<nRecs::16, records::binary>> = baseTbl
    # 2 bytes per class
    recordSize = nClasses * 2
    records = binary_part(records, 0, nRecs * recordSize)
    records = for << <<record::binary-size(recordSize)>> <- records >>, do: record
    # each record is array of offsets
    # 6 bytes is a bit of a cheat, can be 6-10 bytes 
    baseArray = records
              |> Enum.map(fn r -> for << <<offset::16>> <- r>>, do: offset end)
              |> Enum.map(&Enum.map(&1, fn o -> 
                                Parser.parseAnchor(binary_part(baseTbl, o, 6)) end) 
                        )

    markArrayTbl = Parser.subtable(table, markArrayOffset)
    markArray = Parser.parseMarkArray(markArrayTbl)

    adjusted = applyMarkToBase(markCoverage, baseCoverage, baseArray, markArray, flag, mfs, gdef, [hd(glyphs)], tl(glyphs), pos, [nil])
    #Logger.debug "MKMK #{inspect glyphs} #{inspect adjusted}"
    positioning = Enum.zip(pos, adjusted) |> Enum.map(fn {v1, v2} -> addPos(v1,v2) end)
    {glyphs, positioning, c, m}
  end

  # type 7 - contextual positioning
  def applyLookupGPOS({7, _flag, table, _mfs}, gdef, lookups, _isRTL, {glyphs, pos, c, m}) do
    <<format::16, details::binary>> = table
    pos = case format do
      1 ->
        Logger.debug "GPOS 7.1 - contextual positioning"
        pos
      2 ->
        <<covOff::16, 
          classDefOff::16,
          nRulesets::16, 
          srsOff::binary-size(nRulesets)-unit(16),
          _::binary>> = details
        coverage = Parser.parseCoverage(Parser.subtable(table, covOff))
        classes = Parser.parseGlyphClass(Parser.subtable(table, classDefOff))
        srs = for << <<offset::16>> <- srsOff >>, do: if offset != 0, do: Parser.subtable(table, offset), else: nil
        rulesets =  srs
                    |> Enum.map(fn ruleset ->
                      if ruleset != nil do
                        <<nRules::16, srOff::binary-size(nRules)-unit(16), _::binary>> = ruleset
                        rules = for << <<offset::16>> <- srOff >>, do: Parser.subtable(ruleset, offset)
                        rules |> Enum.map(&Parser.parseContextSubRule1(&1))
                      else
                        nil
                      end
                    end)
        _positioning = applyContextPos2(coverage, rulesets, classes, gdef, lookups, glyphs, pos, [])
        pos
      3 ->
        Logger.debug "GPOS 7.3 - contextual positioning"
        pos
      _ ->
        Logger.debug "GPOS 7 - contextual positioning format #{format}"
        pos
    end
    {glyphs, pos, c, m}
  end

  # type 8 - chained contextual positioning
  def applyLookupGPOS({8, flag, table, mfs}, gdef, lookups, _isRTL, {glyphs, pos, c, m}) do
    <<format::16, details::binary>> = table
    pos = case format do
      1 ->
        Logger.debug "GPOS 8.1 - chained contextual positioning"
        pos
      2 ->
        Logger.debug "GPOS 8.2 - chained contextual positioning"
        pos
      3 ->
        <<backtrackCount::16, backoff::binary-size(backtrackCount)-unit(16),
          inputCount::16, inputOff::binary-size(inputCount)-unit(16),
          lookaheadCount::16, lookaheadOff::binary-size(lookaheadCount)-unit(16),
          substCount::16, substRecs::binary-size(substCount)-unit(32),
          _::binary>> = details
        
        # parse the coverage tables and positioning records  
        backOffsets = for << <<x::16>> <- backoff >>, do: x
        btCoverage = Enum.map(backOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)
        inputOffsets = for << <<x::16>> <- inputOff >>, do: x
        coverage = Enum.map(inputOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)
        lookaheadOffsets = for << <<x::16>> <- lookaheadOff >>, do: x
        laCoverage = Enum.map(lookaheadOffsets, fn covOff -> Parser.parseCoverage(Parser.subtable(table, covOff)) end)

        # index x at which to apply lookup y
        posRecords = for << <<x::16, y::16>> <- substRecs >>, do: {x, y}

        g = filter_glyphs(glyphs, flag, gdef, mfs) |> Enum.to_list
        #positioning = List.duplicate(nil, length(pos))
        applyChainingContextPos3(btCoverage, coverage, laCoverage, posRecords, gdef, lookups, g, pos, [])
      _ ->
        Logger.debug "GPOS 8 - chained contextual positioning format #{format}"
        pos
    end
    {glyphs, pos, c, m}
  end

  #unhandled type; log and leave input untouched
  def applyLookupGPOS({type, _flag, _table, _mfs}, _gdef,_lookups, _isRTL, {glyphs, pos, c, m}) do
    Logger.debug "Unknown GPOS lookup type #{type}"
    {glyphs, pos, c, m}
  end

  defp applyMarkToBase(_markCoverage, _baseCoverage, _baseArray, _markArray, _lookupFlag, _mfs, _gdef, _prev, [], _, output), do: Enum.reverse(output)
  defp applyMarkToBase(markCoverage, baseCoverage, baseArray, markArray, lookupFlag, mfs, gdef, prev, [g | glyphs], [prev_pos | pos], output) do
    # should we skip this glyph?
    skipMark = should_skip_glyph(g, lookupFlag, gdef, mfs)

    # TODO: this code assumes prev is a base
    markloc = findCoverageIndex(markCoverage, g)
    baseloc = findCoverageIndex(baseCoverage, hd(prev))
    mark_offset = if markloc != nil and baseloc != nil and !skipMark do
      b = Enum.at(baseArray, baseloc)
      {class, {mark_x, mark_y}} = Enum.at(markArray, markloc)
      {base_x, base_y} = Enum.at(b, class)
      # align the anchors
      {off_x, off_y} = {base_x - mark_x, base_y - mark_y}
      # TODO: possibly do the base calculations later when actually rendering?
      #   doing so requires us to save mark/base relationship somewhere
      #   but potentially gives more accurate results
      # get the base positioning
      {_, box, boy, bax, bay} = prev_pos
      # mark_offset = (base_offset + offset - base_advance)
      # Logger.debug "OFFSET #{off_x} base #{base_x} mark #{mark_x} less #{bax}"
      #{box + off_x - bax, boy + off_y - bay, 0, 0}
      {box + off_x, boy + off_y, 0, 0}
    else
      nil
    end
    applyMarkToBase(markCoverage, baseCoverage, baseArray, markArray, lookupFlag, mfs, gdef, [g | prev], glyphs, pos, [mark_offset | output])
  end

  defp applyKerning2(_classDef1, _clasDef2, _pairSets, [], output), do: output
  defp applyKerning2(_classDef1, _clasDef2, _pairSets, [_], output), do: output ++ [nil]
  defp applyKerning2(classDef1, classDef2, pairsets, [g1, g2 | glyphs], output) do
    c1 = classifyGlyph(g1, classDef1)
    c2 = classifyGlyph(g2, classDef2)
    pair = pairsets |> Enum.at(c1) |> Enum.at(c2)
    {output, glyphs} = if pair != nil do
      {v1, v2} = pair
      oo = output ++ [v1]
      if v2 != nil do
        {oo ++ [v2], glyphs}
      else
        {oo, [g2 | glyphs]}
      end
    else
      {output ++ [nil], [g2 | glyphs]}
    end
    applyKerning2(classDef1, classDef1, pairsets, glyphs, output)
  end

  defp applyKerning(_coverage, _pairSets, [], output), do: output
  defp applyKerning(_coverage, _pairSets, [_], output), do: output ++ [nil]
  defp applyKerning(coverage, pairSets, [g | glyphs], output) do
    # get the index of a pair set that might apply
    coverloc = findCoverageIndex(coverage, g)
    {output, glyphs} = if coverloc != nil do
      pairSet = Enum.at(pairSets, coverloc)
      nextChar = hd(glyphs)
      pair = Enum.find(pairSet, fn {g, _, _} -> g == nextChar end)
      if pair != nil do
        {_, v1, v2} = pair
        oo = output ++ [v1]
        if v2 != nil do
          {oo ++ [v2], tl(glyphs)}
        else
          {oo, glyphs}
        end
      else
        {output ++ [nil], glyphs}
      end
    else
      {output ++ [nil], glyphs}
    end
    applyKerning(coverage, pairSets, glyphs, output)
  end

  defp applyCursive(_coverage, _anchorPairs, _flag, _mfs, _gdef, _isRTL,  [], [], output, deltas), do: {Enum.reverse(output), Enum.reverse(deltas)}
  defp applyCursive(_coverage, _anchorPairs, _flag, _mfs, _gdef, _isRTL,  [_], [p], output, deltas), do: {Enum.reverse([p | output]), Enum.reverse([0 | deltas])}
  defp applyCursive(coverage, anchorPairs, flag, mfs, gdef, isRTL, [g, g2 | glyphs], [p, p2 | pos], output, deltas) do
    # decompose the flag
    <<_attachmentType::8, _::3, _useMark::1, _ignoreMark::1, _ignoreLig::1, _ignoreBase::1, rtl::1>> = <<flag::16>>

    skipCur = should_skip_glyph(g, flag, gdef, mfs)

    #TODO: clean up this mess of compiler warnings
    skipped = []
    pskipped = []
    skipNext = should_skip_glyph(g2, flag, gdef, mfs)
    if skipNext do
      gtemp = [g2 | glyphs]
      ptemp = [p2 | pos]
      skipped = gtemp |> Enum.take_while(fn x -> should_skip_glyph(x, flag, gdef, mfs) end)
      numSkipped = length(skipped)
      if numSkipped < length(gtemp) do 
        pskipped = ptemp |> Enum.take(numSkipped)
        [g2 | glyphs] = gtemp |> Enum.drop(numSkipped)
        [p2 | pos] = ptemp |> Enum.drop(numSkipped)
        #IO.puts "cursive skip next #{inspect skipped}"
      else
        skipped = []
        pskipped = []
        skipCur = true
      end
    end

    curloc = findCoverageIndex(coverage, g)
    nextloc = findCoverageIndex(coverage, g2)


    # if glyphs are covered
    [cur, next, gdelta] = if curloc != nil and nextloc != nil and !skipCur do
      {entryA, _} = Enum.at(anchorPairs, nextloc)
      {_, exitA} = Enum.at(anchorPairs, curloc)
      if exitA != nil and entryA != nil do
        {entry_x, entry_y} = entryA
        {exit_x, exit_y} = exitA
        {_, xOff, yOff, xAdv, yAdv} = p
        {_, x2Off, y2Off, x2Adv, y2Adv} = p2
        delta_y = if rtl, do: entry_y - exit_y, else: exit_y - entry_y
        index_delta = length(skipped) + 1


        if isRTL do
          delta_x = exit_x + xOff
          # post-process -- our yOffset needs to be adjusted by next yOffset
          # Logger.debug "GPOS 3 - cursive RTL delta #{inspect delta_x}, #{inspect delta_y}"
          [{:pos, xOff - delta_x, delta_y, xAdv - delta_x, yAdv}, {:pos, x2Off, y2Off, entry_x + x2Off, y2Adv}, index_delta]
        else
          delta_x = entry_x + x2Off
          # post-process -- next needs to adjust yOffset by our yOffset
          #Logger.debug "GPOS 3 - cursive LTR delta #{inspect delta_x}, #{inspect delta_y}"
          [{:pos, xOff, delta_y, exit_x + xOff, yAdv}, {:pos, x2Off - delta_x, y2Off, x2Adv - delta_x, y2Adv}, -index_delta]
        end
      else
        [p, p2, 0]
      end
    else
      [p, p2, 0]
    end
    applyCursive(coverage, anchorPairs, flag, mfs, gdef, isRTL, skipped ++ [g2 | glyphs], pskipped ++ [next | pos], [cur | output], [gdelta | deltas])
  end

  # adjust the y-offsets of connected glyphs
  def adjustCursiveOffset(positions, deltas) do
    0..length(deltas)-1
    |> Enum.reduce({positions, deltas}, fn (x, {p, d}) -> adjustCursiveOffsets(x, p, d) end)
  end

  # this is recursive since offset accumulates over a run of connected glyphs
  # Urdu in particular shows this in action
  def adjustCursiveOffsets(index, positions, deltas) do
    d = Enum.at(deltas, index)
    if d == 0 do
      {positions, deltas}
    else
      next = index + d
      {p2, d2} = adjustCursiveOffsets(next, positions, List.replace_at(deltas, index, 0))
      {type, xo, yo, xa, ya} = Enum.at(p2, index)
      {_, _, yo2, _, _} = Enum.at(p2, next)

      {List.replace_at(p2, index, {type, xo, yo + yo2, xa, ya}), d2}
    end

  end

  # class-based context
  defp applyContextPos2(_coverage, _rulesets, _classes, _gdef, _lookups, [], [], output), do: output
  defp applyContextPos2(coverage, rulesets, classes, gdef, lookups, [g | glyphs], [p | pos], output) do
    coverloc = findCoverageIndex(coverage, g)
    ruleset = Enum.at(rulesets, classifyGlyph(g, classes))
    {o, glyphs, pos} = if coverloc != nil  and ruleset != nil do
      #find first match in this ruleset
      # TODO: flag might mean we need to filter ignored categories
      # ie; skip marks
      rule = Enum.find(ruleset, fn {input, _} ->
                        candidates = glyphs
                          |> Enum.take(length(input))
                          |> Enum.map(fn g -> classifyGlyph(g, classes) end)
                         candidates == input 
                       end)
      if rule != nil do
        Logger.debug "GPOS7.2 rule = #{inspect rule}"
        {matched, substRecords} = rule
        input = [g | Enum.take(glyphs, length(matched))]
                |> Enum.zip([p | Enum.take(pos, length(matched))])
        replaced = substRecords
        |> Enum.reduce(input, fn {inputLoc, lookupIndex}, acc ->
          {candidate, candidate_position} = Enum.at(acc, inputLoc)
          lookup = Enum.at(lookups, lookupIndex)
          # applyLookupGPOS({type, _flag, _table}, _gdef,_lookups, _isRTL, {glyphs, pos}) do
          [adjusted_pos | _] = applyLookupGPOS(lookup, gdef, lookups, nil, {[candidate], [candidate_position]})
          List.replace_at(acc, inputLoc, {candidate, adjusted_pos})
        end)
        # skip over any matched glyphs
        # TODO: handle flags correctly
        # probably want to prepend earlier ignored glyphs to remaining
        remaining = Enum.slice(glyphs, length(matched), length(glyphs))
        remaining_pos = Enum.slice(pos, length(matched), length(pos))
        Logger.debug("#{inspect input} => #{inspect replaced}")
        #{replaced, remaining, remaining_pos}
        {[nil], glyphs, pos}
      else
        {[nil], glyphs, pos}
      end
    else
      {[nil], glyphs, pos}
    end
    output = output ++ o
    applyContextPos2(coverage, rulesets, classes, gdef, lookups, glyphs, pos, output)
  end

  # handle coverage-based format for context chaining
  defp applyChainingContextPos3(_btCoverage, _coverage, _laCoverage, _subst, _gdef, _lookups, [], pos, _), do: pos
  defp applyChainingContextPos3(btCoverage, coverage, laCoverage, posRecords, gdef, lookups, [{g, index} | glyphs], pos, output) do
    backtrack = length(btCoverage)
    inputExtra = length(coverage) - 1
    lookahead = length(laCoverage)
    #not enough backtracking or lookahead to even attempt match
    oo = if length(output) < backtrack or length(glyphs) < lookahead + inputExtra do
      # positioning unchanged
      pos
    else

      #do we match the input
      input = [{g, index} | Enum.take(glyphs, inputExtra)]
      inputMatches = input
                     |> Enum.zip(coverage)
                     |> Enum.all?(fn {{g, _index}, cov} -> findCoverageIndex(cov, g) != nil end)

      #do we match backtracking?
      backMatches = if backtrack > 0 do
        output
        |> Enum.take(backtrack)
        |> Enum.zip(btCoverage)
        |> Enum.all?(fn {{g, _index}, cov} -> findCoverageIndex(cov, g) != nil end)
      else
        true
      end

      #do we match lookahead
      laMatches = if lookahead > 0 do
        glyphs
        |> Enum.drop(inputExtra)
        |> Enum.take(lookahead)
        |> Enum.zip(laCoverage)
        |> Enum.all?(fn {{g, _index}, cov} -> findCoverageIndex(cov, g) != nil end)
      else
        true
      end

      if inputMatches and backMatches and laMatches do
        posRecords
        |> Enum.reduce(pos, fn ({inputIndex, lookupIndex}, accPos) ->
          lookup = Enum.at(lookups, lookupIndex)
          {g, index} = Enum.at(input, inputIndex)
          candidate_position = Enum.at(accPos, index)
          # we only care about the new pos
          {_, [adjusted_pos | _], _, _} = applyLookupGPOS(lookup, gdef, lookups, nil, {[g], [candidate_position], [], []})
          List.replace_at(accPos, index, adjusted_pos)
        end)
      else
        pos
      end
    end
    # oo is the possibly updated positioning
    # output will be used for backtracking
    applyChainingContextPos3(btCoverage, coverage, laCoverage, posRecords, gdef, lookups, glyphs, oo, [{g, index} | output])
  end


  # given a glyph, find out the coverage index (can be nil)
  defp findCoverageIndex(cov, g) when is_integer(hd(cov)) do
    Enum.find_index(cov, fn i -> i == g end)
  end
  defp findCoverageIndex(cov, g) when is_tuple(hd(cov)) do
    r = Enum.find(cov, fn {f,l,_} -> f <= g and g <= l end)
    if r != nil do
      {s,_,i} = r
      i + g - s
    else
      nil
    end
  end
  # catch-all
  defp findCoverageIndex(_cov, _g) do
    nil
  end

  defp classifyGlyph(_g, nil), do: 0
  defp classifyGlyph(g, classes) when is_map(classes) do
    Map.get(classes, g, 0)
  end
  defp classifyGlyph(g, ranges) do
    r = Enum.find(ranges, fn {f,l,_} -> f <= g and g <= l end)
    # if no match, class 0
    if r == nil do
      0
    else
      {_,_,class} = r
      class
    end
  end

  # uses the lookup flag to determine which glyphs are ignored
  def should_skip_glyph(g, flag, gdef, mfs) do
    # decompose the flag
    <<attachmentType::8, _::3, useMarkFilteringSet::1, ignoreMark::1, ignoreLig::1, ignoreBase::1, _rtl::1>> = <<flag::16>>

    # only care about classification if flag set
    glyphClass = if flag > 1 do
      classifyGlyph(g, gdef.classes)
    else
      0
    end

    cond do
      # short circuit - if no flags, we aren't skipping anything
      flag == 0 -> false
      # if only RTL flag not skipping anything
      flag == 1 -> false
      # skip if ignore is set and we match the corresponding GDEF class
      ignoreBase == 1 and glyphClass == 1 -> true
      ignoreLig  == 1 and glyphClass == 2 -> true
      ignoreMark == 1 and glyphClass == 3 -> true
      # DO NOT SKIP if specified mark glyph set but not a mark
      useMarkFilteringSet == 1 and glyphClass != 3  -> false
      # skip if we have a mark that isn't in specified mark glyph set
      useMarkFilteringSet == 1 and classifyGlyph(g, gdef.classes) == 3 and findCoverageIndex(Enum.at(gdef.mark_sets, mfs), g) == nil -> true
      # skip if we don't match a non-zero attachment type
      attachmentType != 0 and classifyGlyph(g, gdef.attachments) != attachmentType -> true
      # default is DO NOT SKIP
      true -> false
    end
  end

  # then we use / save {pos, index}
  # returns array of {glyph, index} of glyphs that are not ignored (according to lookup flag)
  def filter_glyphs(glyphs, flag, gdef, mfs) do
    glyphs
    |> Stream.with_index
    |> Stream.reject(fn {g, _} -> should_skip_glyph(g, flag, gdef, mfs) end)
  end

end
