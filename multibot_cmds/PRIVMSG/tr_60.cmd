#!/bin/bash
# 60 = `

. lib/dcc
. lib/interp

# Undo commands stored here
export UNDO="true"

die() {
    bash -c "$UNDO"
    if [ "$IRC_SOCK" != "" ]
    then
        echo "PRIVMSG $CHANNEL :$1" | socat STDIN UNIX-SENDTO:"$IRC_SOCK"
    else
        echo "$1"
    fi
    exit 1
}

undo() {
    export UNDO="$UNDO; $1"
}

maybe_dcc_chat() {
    if [ "$IRC_SOCK" != "" ]
    then
        dcc_chat "$@"
    else
        cat
    fi
}

if [ "$IRC_SOCK" != "" ]
then
    CMD=`echo "$3" | sed 's/^.//'`
    CHANNEL="$2"
    if ! expr "$CHANNEL" : "#" > /dev/null
    then
        CHANNEL="$IRC_NICK"
    fi
else
    CMD="$1"
fi
SCMD=`echo "$CMD" | sed 's/^\([^ ]*\) .*$/\1/'`
ARG=`echo "$CMD" | sed 's/^\([^ ]*\) *//'`
CMD="$SCMD"

# Ignore Lymee
test "$IRC_NICK" = "Lymee" && die 'Mmmmm ... no.'

# Now clone the environment
export HACKENV="/tmp/hackenv.$$"
hg clone env "$HACKENV" >& /dev/null || die 'Failed to clone the environment!'
undo "cd; rm -rf $HACKENV"
cd "$HACKENV" || die 'Failed to enter the environment!'

# And get .hg somewhere "safe"
export HACKHG="/tmp/hackenv.hg.$$"
mv .hg $HACKHG >& /dev/null || die 'Failed to clone the environment!'
undo "rm -rf $HACKHG"

# Add it to the PATH
export POLA_PATH="/hackenv/bin:/opt/python27/bin:/opt/ghc/bin:/usr/bin:/bin"

# Now run the command
runcmd() {
    (
        export http_proxy='http://127.0.0.1:3128'

        pola-nice "$@" | 
            head -c 16384 |
            perl -pe 's/\n/ \\ /g' |
            fmt -w350 |
            sed 's/ \\$//'
        echo ''
    ) | (
        if [ "$IRC_SOCK" != "" ]
        then
            read -r LN
            if [ "$LN" ]; then
                LN=`echo "$LN" | sed 's/[\x01-\x1F]/./g ; s/^\([^a-zA-Z0-9]\)/\xE2\x80\x8B\1/ ; s/\\\\/\\\\\\\\/g'`
                echo -e 'PRIVMSG '$CHANNEL' :'"$LN" | socat STDIN UNIX-SENDTO:"$IRC_SOCK"
            else
                echo 'PRIVMSG '$CHANNEL' :No output.' | socat STDIN UNIX-SENDTO:"$IRC_SOCK"
            fi

            # Discard remaining output
            cat > /dev/null
    
        else
            cat
        fi
    )
}

(
    # Special commands
    if [ "$CMD" = "help" ]
    then
        echo 'PRIVMSG '$CHANNEL' :Runs arbitrary code in GNU/Linux. Type "`<command>", or "`run <command>" for full shell commands. "`fetch <URL>" downloads files. Files saved to $PWD are persistent, and $PWD/bin is in $PATH. $PWD is a mercurial repository, "`revert <rev>" can be used to revert to a revision. See http://codu.org/projects/hackbot/fshg/' |
            socat STDIN UNIX-SENDTO:"$IRC_SOCK"

    elif [ "$CMD" = "fetch" ]
    then
        (
            ulimit -f 10240
            (wget -nv "$ARG" < /dev/null 2>&1 | tr "\n" " "; echo) |
                sed 's/^/PRIVMSG '$CHANNEL' :/' |
                socat STDIN UNIX-SENDTO:"$IRC_SOCK"
        )

    elif [ "$CMD" = "run" ]
    then
        runcmd sh -c "$ARG"

    elif [ "$CMD" = "revert" ]
    then
        if [ "$ARG" = "" ]
        then
            REV=-2
        else
            REV=$ARG
        fi
        mv $HACKHG .hg 2>&1
        OUTPUT=$(hg revert --all -r "$REV" 2>&1)
        if [ $? -eq 0 ]
        then
            MSG="Done."
        else
            MSG=$OUTPUT
        fi
        echo 'PRIVMSG '$CHANNEL' :'$MSG | socat STDIN UNIX-SENDTO:"$IRC_SOCK"
        mv .hg $HACKHG

    else
        if [ "$ARG" = "" ]
        then
            runcmd "$CMD"
        else
            runcmd "$CMD" "$ARG"
        fi
    fi

    # Now commit the changes (make multiple attempts in case things fail)
    if [ -e .hg ] ; then die "Invalid .hg directory found." ; fi
    if [ ! -e canary ] ; then exit 1 ; fi
    mv $HACKHG .hg 2>&1
    for (( i = 0; $i < 10; i++ ))
    do
        find . -name '*.orig' | xargs rm -f
        hg addremove >& /dev/null || die "Failed to record changes."
        hg commit -m "<$IRC_NICK> $CMD $ARG" >& /dev/null || 
        hg commit -m "<$IRC_NICK> (unknown command)" >& /dev/null ||
        hg commit -m "No message" #|| die "Failed to record changes."
    
        hg push >& /dev/null && break || (
            # Failed to push, that means we need to pull and merge
            hg pull >& /dev/null
            for h in `hg heads --template='{node} ' 2> /dev/null`
            do
                hg merge $h >& /dev/null
                hg commit -m 'branch merge' >& /dev/null
                hg revert --all >& /dev/null
                find . -name '*.orig' 2> /dev/null | xargs rm -f >& /dev/null
            done
        )
    done
) &

sleep 30
kill -9 %1

# And get rid of our tempdir
bash -c "$UNDO"
