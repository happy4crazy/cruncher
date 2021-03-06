$ ->
    window.editor = editor = null
    window.editor = editor = CodeMirror.fromTextArea $('#code')[0],
        lineNumbers: true
        lineWrapping: true,
        theme: 'cruncher'

    CodeMirror.keyMap.default['Enter'] = ->
        # custom handling of Enter key so that if user does (cursor is |)
        # 2 + 2| = 4
        # 2 + 2\n = 4
        # the 2 + 2 = 4 is preserved on the previous line,
        # instead of breaking weirdly
        # 2 + 2 = 4
        # |
        
        cursor = editor.getCursor()
        cursor.ch += 1

        token = editor.getTokenAt cursor
        aroundEquals = token.type == 'equals'

        while token.string != '' and not aroundEquals and token.type == null
            token = editor.getTokenAt
                line: cursor.line
                ch: token.end + 1
            aroundEquals = token.type == 'equals'

        if aroundEquals
            eol =
                line: cursor.line
                ch: editor.getLine(cursor.line).length
            
            editor.replaceRange '\n', eol, eol
            editor.setCursor
                line: cursor.line + 1
                ch: 0
            
        else
            editor.replaceRange '\n', cursor, cursor

        evalLine cursor.line + 1        

    updateMarksAfterEdit = (from, to) ->
        # after doc is edited,
        # relocate/rebuild markers for free variables
        
        freeMark = editor.findMarksAt(from)[0]
        console.log editor.getAllMarks()
        return unless freeMark?

        token = editor.getTokenAt to
        console.log freeMark.getOptions()
        newMark = editor.markText { line: to.line, ch: token.start },
            { line: to.line, ch: token.end },
            freeMark.getOptions()
        freeMark.clear()
        
        console.log 'you edited an unlocked region', freeMark, newMark

    fixCursor = (oldCursor) ->
        # runs while evaluating and constraining a line
        # returns weakened version of onChange handler that just makes sure
        # user's cursor stays in a sane position while we evalLine

        return (instance, changeObj) ->
            return unless oldCursor.line == changeObj.to.line

            if oldCursor.ch > changeObj.from.ch
                cursorOffset = changeObj.text[0].length - (changeObj.to.ch - changeObj.from.ch)
                editor.setCursor
                    line: oldCursor.line
                    ch: oldCursor.ch + cursorOffset

                # TODO put this somewhere else so drag logic isn't mixed with eval logic
                if draggingState?
                    draggingState.start.ch += cursorOffset
                    draggingState.end.ch += cursorOffset
            else
                editor.setCursor oldCursor
            
            console.log 'editing', oldCursor, changeObj

    evalLine = (line) ->
        # runs after a line changes and it's been re-marked with
        # its current free variables
        # (except, of course, when evalLine is the changer)
        # reconstrain the free variable(s) [currently only 1 is supported]
        # so that the equation is true,
        # or make the line an equation
        
        editor.off 'change', onChange
        fixOnChange = fixCursor editor.getCursor()
        editor.on 'change', fixOnChange
        
        text = editor.getLine line
        handle = editor.getLineHandle line

        textToParse = text
        freeMarks = []
        if handle?.markedSpans?
            freeMarks = handle.markedSpans
            
            markedPieces = []
            start = 0
            for freeMark in freeMarks
                console.log freeMark
                markedPieces.push (text.substring start, freeMark.from)
                start = freeMark.to
            markedPieces.push (text.substring start, text.length)

            console.log markedPieces
            textToParse = markedPieces.join '&FREE&' # horrifying hack

        console.log textToParse            
        try
            parsed = parser.parse textToParse
        catch e
            parsed = null

        if parsed?.constructor == Value # edited a line without another side (yet)
            freeString = parsed.toString()

            from =
                line: line
                ch: text.length + ' = '.length
            to =
                line: line
                ch: text.length + ' = '.length + freeString.length

            editor.replaceRange ' = ' + freeString, from, from

            editor.markText from, to, { className: 'free-number' }
            
        else if parsed?.constructor == Equation
            # search for free variables that we can change to keep the equality constraint
            if freeMarks.length < 1
                console.log 'This equation cannot be solved! Not enough freedom'

            else if freeMarks.length == 1
                console.log 'Solvable if you constrain', freeMarks
                [leftF, rightF] = for val in [parsed.left, parsed.right]
                    do (val) -> if typeof val.num == 'function' then val.num else (x) -> val.num
                window.leftF = leftF
                window.rightF = rightF

                try
                    solution = (numeric.uncmin ((x) -> (Math.pow (leftF x[0]) - (rightF x[0]), 2)), [1]).solution[0]
                    solutionText = solution.toFixed 2
                    console.log 'st', solutionText

                    editor.replaceRange solutionText,
                        { line: line, ch: freeMarks[0].from },
                        { line: line, ch: freeMarks[0].to }
                    
                    editor.markText { line: line, ch: markedPieces[0].length },
                        { line: line, ch: markedPieces[0].length + solutionText.length },
                        { className: 'free-number' }
                catch e
                    console.log 'The numeric solver was unable to solve this equation!'

            else
                console.log 'This equation cannot be solved! Too much freedom', freeMarks
            
            # textSides = text.split('=')
            # if oldCursor.ch < text.indexOf('=')
            #     editor.setLine line, textSides[0] + '= ' + parsed.left.toString()
            # else
            #     editor.setLine line, parsed.right.toString() + ' =' + textSides[1]

            #     cursorOffset = -textSides[0].length + parsed.right.toString().length + 1
            #     oldCursor.ch = oldCursor.ch + cursorOffset

        editor.off 'change', fixOnChange
        editor.on 'change', onChange

    onChange = (instance, changeObj) ->
        # executes on user or cruncher change to text
        # (except during evalLine)
        
        return if not editor

        updateMarksAfterEdit changeObj.from, changeObj.to
        
        line = changeObj.to.line
        evalLine line
    
    editor.on 'change', onChange

    nearestNumberToken = (pos) ->
        # find nearest number token to pos = { line, ch }
        # used for identifying hover/drag target
        
        token = editor.getTokenAt pos

        if token.type != 'number'
            pos.ch += 1
            token = editor.getTokenAt pos

        if token.type != 'number'
            return null

        return token

    draggingState = null

    ($ document).on('mouseenter', '.cm-number', (enterEvent) ->
        # add hover class, construct number widget
        # when user hovers over a number
        
        if draggingState? then return

        hoverPos = editor.coordsChar(
            left: enterEvent.pageX,
            top: enterEvent.pageY
        )

        hoverToken = nearestNumberToken hoverPos

        if not hoverToken?
            hoverPos = editor.coordsChar(
                left: enterEvent.pageX,
                top: enterEvent.pageY + 2 # ugly hack because coordsChar's hit box doesn't quite line up with the DOM hover hit box
            )
            hoverToken = nearestNumberToken hoverPos
        
        console.log hoverToken

        if hoverToken?
            ($ '.hovering-number').removeClass 'hovering-number'
            
            ($ '.number-widget').stop(true)

            ($ this).addClass 'hovering-number'
            
            (new NumberWidget hoverToken, hoverPos, (line) -> evalLine line).show()
        
    ).on 'mousedown', '.cm-number', (downEvent) ->
        # initiate and handle dragging/scrubbing behavior
        
        ($ this).addClass 'dragging-number'
        ($ '.number-widget').remove()

        draggingState = dr = {}
        
        dr.origin = editor.getCursor()
        
        token = nearestNumberToken dr.origin
        
        dr.value = Number(token.string)
        dr.fixedDigits = token.string.split('.')[1]?.length ? 0
        
        dr.start = line: dr.origin.line, ch: token.start
        dr.end = line: dr.origin.line, ch: token.end

        xCenter = downEvent.pageX
        
        ($ document).mousemove((moveEvent) =>
            editor.setCursor dr.start # disable selection

            xOffset = moveEvent.pageX - xCenter
            xCenter = moveEvent.pageX
            
            delta = if xOffset >= 2 then 1 else if xOffset <= -2 then -1 else 0
            console.log xOffset / (Math.abs xOffset)

            if delta != 0
                dr.value += delta
                
                valueString = dr.value.toFixed dr.fixedDigits
                editor.replaceRange valueString, dr.start, dr.end

                dr.end.ch = dr.start.ch + valueString.length
        ).mouseup =>
            ($ '.dragging-number').removeClass 'dragging-number'

            ($ document).unbind('mousemove')
                .unbind 'mouseup'

            draggingState = null
            
            editor.setCursor dr.origin

    editor.refresh()

    evalLine line for line in [0..editor.lineCount() - 1]
