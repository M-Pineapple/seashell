function __nl_enter --description 'Enter key handler: NL routing with spinner + typewriter animations'
    set -l cmdline (commandline -b)
    set -l trimmed (string trim -- $cmdline)

    # Empty → just submit
    if test -z "$trimmed"
        commandline -f execute
        return
    end

    # Strip trailing backslashes (tab-completion artifact)
    set -l trimmed (string replace -r '\\+$' '' -- $trimmed)
    set -l trimmed (string trim -- $trimmed)

    # Extract first token
    set -l first (string split -m1 ' ' -- $trimmed)[1]

    # Strip leading env-var assignments (FOO=bar cmd → check "cmd")
    while string match -q -- '*=*' $first
        set -l rest (string replace -r '^[^=]+=\S*\s*' '' -- $trimmed)
        set trimmed (string trim -- $rest)
        if test -z "$trimmed"; break; end
        set first (string split -m1 ' ' -- $trimmed)[1]
    end

    # ── Resume-intent fast path ──────────────────────────────────────────────
    # Bypass NL classification entirely if the line clearly says "resume X".
    # Mirrors the patterns from `hey` so typing "let's continue with myapp" at
    # the bare fish prompt resumes the project's primary session — no chatbot
    # detour, no need to remember the `hey` prefix.
    set -l trimmed_lc (string lower -- $trimmed)
    set -l resume_target ""

    # Note on `--`: fish's `string replace` already consumes one `--` as the
    # end-of-options marker. A second `--` between REPLACEMENT and STRING gets
    # treated as a LITERAL string argument — so we only emit one `--`, placed
    # immediately before the user-supplied STRING (which might start with `-`).
    if string match -qr -- '(^|.*\b)(let.?s? |let me |let us |please )?continue with ' $trimmed_lc
        set resume_target (string replace -ri '^.*\bcontinue with\s+' '' -- $trimmed)
    else if string match -qr -- '(^|.*\b)(let.?s? |let me |let us |please )?continue working (on|with) ' $trimmed_lc
        set resume_target (string replace -ri '^.*\bcontinue working (on|with)\s+' '' -- $trimmed)
    else if string match -qr -- '(^|.*\b)(let.?s? |let me |let us )work (on|with) ' $trimmed_lc
        set resume_target (string replace -ri '^.*\bwork (on|with)\s+' '' -- $trimmed)
    else if string match -qr -- '^resume ' $trimmed_lc
        set resume_target (string replace -ri '^resume\s+' '' -- $trimmed)
    else if string match -qr -- '(^|.*\b)(go back to |pick up |switch back to |switch to ) ' $trimmed_lc
        set resume_target (string replace -ri '^.*\b(go back to|pick up|switch back to|switch to)\s+' '' -- $trimmed)
    end

    if test -n "$resume_target"
        # Cleanup order matters: punctuation FIRST (otherwise the suffix-strip
        # regex's `$` anchor doesn't match through trailing dots/exclamations),
        # then "called/named X" tails (drops noise like "my Python project
        # called X" → "X"), then trailing fluff (session/project/repo), then
        # leading articles.
        set resume_target (string replace -r '[.!?,]+$' '' -- $resume_target)
        set resume_target (string replace -ri '^.*\b(called|named|labelled|labeled)\s+' '' -- $resume_target)
        set resume_target (string replace -ri '\s+(coding\s+)?(session|project|repo)\s*$' '' -- $resume_target)
        set resume_target (string replace -ri '^(the|our|my|that|this)\s+' '' -- $resume_target)
        set resume_target (string trim -- $resume_target)

        if test -n "$resume_target"
            # `seashell-sessions primary <name>` returns the pinned session id
            # for that project (or falls back to most-recent if unpinned).
            set -l sid (seashell-sessions primary "$resume_target" 2>/dev/null)
            if test -n "$sid"
                # Claude Code looks up `--resume <id>` under
                # `~/.claude/projects/<encoded-cwd>/` where <encoded-cwd>
                # is the CURRENT directory. So we must cd to the session's
                # original cwd before exec'ing, otherwise Claude Code
                # bails with "No conversation found with session ID".
                set -l target_cwd (seashell-sessions cwd "$sid" 2>/dev/null)
                commandline ''
                commandline -f repaint
                set_color cyan
                printf '🔄 Resuming session %s (project: %s)...' (string sub -l 8 -- $sid) "$resume_target"
                set_color normal
                echo ""
                if test -n "$target_cwd"; and test -d "$target_cwd"
                    builtin cd "$target_cwd"
                end
                exec claude --resume "$sid"
            end
            # No live session matched. Before falling through to NL chat
            # classification (which would guess at a `cd` command and probably
            # get the path wrong), search common project parents for a folder
            # whose name matches the resume target. If we find one, offer to
            # start a new claude session there.
            set -l target_norm (string lower -- $resume_target | string replace -ar '[^a-z0-9]' '')
            set -l found_dir ""
            if test -n "$target_norm"
                for parent in $HOME/Github $HOME/Code $HOME/projects $HOME/work $HOME/src $HOME/Documents
                    test -d "$parent"; or continue
                    for entry in $parent/*
                        test -d "$entry"; or continue
                        set -l name_norm (basename -- $entry | string lower | string replace -ar '[^a-z0-9]' '')
                        if test "$target_norm" = "$name_norm"
                            set found_dir "$entry"
                            break
                        end
                    end
                    test -n "$found_dir"; and break
                end
            end

            if test -n "$found_dir"
                commandline ''
                commandline -f repaint
                set_color brblack
                printf '  no live session for "%s". start a new one in:' $resume_target
                set_color normal
                echo ""
                set_color cyan; printf "  ➜  cd %s && claude" $found_dir; set_color normal
                echo ""
                set_color brblack; printf '     run? [Enter / Ctrl+C]  '; set_color normal
                read -P '' -l _confirm
                echo ""
                if test $status -eq 0
                    builtin cd $found_dir
                    exec claude
                end
                return 0
            end

            # No live session AND no matching project dir → fall through to
            # normal NL processing. (User might have meant "continue with the
            # ASCII art" in chat, not a project we can find on disk.)
        end
    end

    # ── Natural language detection ────────────────────────────────────────────
    # Shell commands never contain English articles, possessives, or linking
    # words — so their presence is a reliable NL signal.
    set -l words (string split ' ' -- (string lower -- $trimmed))
    set -l word_count (count $words)
    set -l has_flags (string match -qr -- '(^| )-[a-zA-Z]' $trimmed; and echo yes; or echo no)

    set -l is_nl false

    # Rule 1: ends with ?
    if string match -q -- '*?' $trimmed
        set is_nl true
    end

    # Rule 2: starts with a question word
    if contains -- $words[1] what which who why when where how
        set is_nl true
    end

    # Rule 3: contains English function words that never appear in raw shell commands
    if not $is_nl; and test $word_count -gt 1; and test "$has_flags" = no
        set -l nl_markers \
            the an this that these those \
            my your our their its \
            me him her us them myself yourself \
            is are was were been being \
            have has had will would could should may might must \
            please help want need about
        for w in $words
            if contains -- $w $nl_markers
                set is_nl true
                break
            end
        end
    end

    # Rule 4: action word that doubles as a command (make, copy…) + prose (no flags, 3+ words)
    if not $is_nl; and test $word_count -gt 2; and test "$has_flags" = no
        if contains -- $words[1] make duplicate rename tell explain describe give
            set is_nl true
        end
    end

    # Known command/function/builtin → normal execute (unless detected as NL)
    if not $is_nl; and type -q -- $first 2>/dev/null
        commandline $trimmed
        commandline -f execute
        return
    end

    # ── Path shortcut: "Documents/" or "~/foo/bar/" → cd directly ────────────
    # Avoids Ollama entirely for simple directory navigation
    if string match -q -- '*/' $trimmed
        commandline ''
        commandline -f repaint
        if cd -- $trimmed 2>/dev/null
            return 0
        end
        # cd failed — fall through to Ollama so it can suggest the right path
    end

    # Ollama not running → fall through to normal execute
    if not curl -s --max-time 1 http://localhost:11434 >/dev/null 2>&1
        commandline $trimmed
        commandline -f execute
        return
    end

    # ── Setup ─────────────────────────────────────────────────────────────────
    set -l original_query $trimmed
    set -l query_parts (string split ' ' -- $trimmed)
    commandline ''
    commandline -f repaint
    echo ""

    set -l frames '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'

    # ── Spinner while Ollama classifies + generates ───────────────────────────
    set -l tmp_out /tmp/nl_out_{$fish_pid}
    python3 ~/.config/fish/nl_handler.py $PWD $query_parts >$tmp_out 2>/dev/null &
    set -l nl_pid $last_pid

    set -l f 1
    while kill -0 $nl_pid 2>/dev/null
        set_color brblue
        printf "\r  %s  thinking..." $frames[$f]
        set_color normal
        set f (math \( $f % (count $frames) \) + 1)
        sleep 0.08
    end
    wait $nl_pid 2>/dev/null
    printf "\r\033[2K"

    set -l result (cat $tmp_out 2>/dev/null)
    rm -f $tmp_out

    if test -z "$result"
        set_color red; printf "  ✗  No response\n"; set_color normal
        echo ""
        return 0
    end

    # ── General knowledge answer ──────────────────────────────────────────────
    if string match -q -- 'QUESTION:*' $result
        set -l answer (string replace -- 'QUESTION:' '' $result)
        set_color yellow; printf "  ℹ  "; set_color normal
        set_color yellow
        for ch in (string split '' -- $answer)
            printf "%s" $ch
            sleep 0.015
        end
        set_color normal
        echo ""

        # If the answer contains a backtick command, offer to run it
        set -l suggested (string match -r -- '`[^`]+`' $answer | string replace -a -- '`' '')
        if test -n "$suggested"
            echo ""
            set_color brblack; printf "  run "; set_color normal
            set_color cyan; printf "%s" $suggested; set_color normal
            set_color brblack; printf "? [Enter / Ctrl+C]  "; set_color normal
            read -P '' -l confirm
            echo ""
            if test $status -eq 0
                eval $suggested
            end
        end

        echo ""
        return 0
    end

    # ── Shell command ─────────────────────────────────────────────────────────
    if string match -q -- 'COMMAND:*' $result
        # Strip any trailing backslash the model may have emitted
        set -l cmd (string replace -- 'COMMAND:' '' $result)
        set -l cmd (string replace -r '\\+$' '' -- $cmd)
        set -l cmd (string trim -- $cmd)

        # Typewriter reveal of command
        set_color cyan; printf "  ➜  "; set_color normal
        set_color cyan
        for ch in (string split '' -- $cmd)
            printf "%s" $ch
            sleep 0.022
        end
        set_color normal
        echo ""

        # Confirm before running
        set_color brblack; printf "     run? [Enter / Ctrl+C]  "; set_color normal
        read -P '' -l confirm
        echo ""

        # Run the command
        eval $cmd
        set -l exit_code $status

        # ── On success only: one-line explanation ─────────────────────────────
        if test $exit_code -eq 0
            set -l tmp_exp /tmp/nl_exp_{$fish_pid}

            python3 -c "
import json, subprocess, sys, re
q, c = sys.argv[1], sys.argv[2]
payload = json.dumps({'model':'qwen2.5-coder:1.5b','stream':False,'keep_alive':'30m','messages':[
    {'role':'system','content':'Explain shell commands in ONE sentence of max 12 words. No bullet points. No newlines. Output only that one sentence.'},
    {'role':'user','content':f'Command: {c}'}]})
r = subprocess.run(['curl','-s','--max-time','8','http://localhost:11434/api/chat',
    '-H','content-type: application/json','-d',payload],capture_output=True,text=True)
out = json.loads(r.stdout)['message']['content'].strip()
first = re.split(r'(?<=[.!?])\s', out)[0]
print(first[:120])
" "$original_query" "$cmd" >$tmp_exp 2>/dev/null &
            set -l exp_pid $last_pid

            set -l f 1
            echo ""
            while kill -0 $exp_pid 2>/dev/null
                set_color bryellow
                printf "\r  %s  " $frames[$f]
                set_color normal
                set f (math \( $f % (count $frames) \) + 1)
                sleep 0.08
            end
            wait $exp_pid 2>/dev/null
            printf "\r\033[2K"

            set -l explanation (cat $tmp_exp 2>/dev/null)
            rm -f $tmp_exp

            if test -n "$explanation"
                set_color yellow; printf "  ℹ  "; set_color normal
                set_color yellow
                for ch in (string split '' -- $explanation)
                    printf "%s" $ch
                    sleep 0.012
                end
                set_color normal
                echo ""
            end
        end

        echo ""
        return $exit_code
    end

    # Unrecognised response → restore and execute normally
    commandline $original_query
    commandline -f execute
end
