#!/usr/bin/env python
# 60 = `

import sys
import os
import shutil
import socket
import stat
import string
import subprocess
import fcntl
import re

ignored_nicks = ['Lymia', 'Lymee', 'Madoka-Kaname']

help_text = '''\
Runs arbitrary code in GNU/Linux. Type "`<command>", or "`run \
<command>" for full shell commands. "`fetch [<output-file>] <URL>" \
downloads files. Files saved to $PWD are persistent, and $PWD/bin is in \
$PATH. $PWD is a mercurial repository, "`revert <rev>" can be used to \
revert to a revision. See http://codu.org/projects/hackbot/fshg/\
'''

irc = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
irc.connect(os.environ['IRC_SOCK'])

message = sys.argv[3][1:]
channel = sys.argv[2]
if not channel.startswith('#'):
    channel = os.environ['IRC_NICK']

def say(text):
    irc.send('PRIVMSG %s :%s\n' % (channel, text))

def chmod_sane(path, executable):
    mode = stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH
    if executable: mode |= stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    try:
        os.chmod(path, mode)
    except OSError:
        pass  # well, we tried

def calldevnull(*args):
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, close_fds=True)
    p.communicate()

def callLimit(args, exclusive):
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, close_fds=True)
    p.stdin.close()
    ret = p.stdout.read(1024)
    p.stdout.close()
    p.wait()
    # Make sure $HACKENV/.hg is accessible by forcing sane permissions on $HACKENV / .hgignore
    chmod_sane(os.environ['HACKENV'], executable=True)
    hgignore = os.path.join(os.environ['HACKENV'], '.hgignore')
    chmod_sane(hgignore, executable=False)
    if exclusive:
        # Ensure the .hgignore file is pristine
        if os.path.isdir(hgignore):
            shutil.rmtree(hgignore, ignore_errors=True)
        calldevnull("hg", "revert", "-R", os.environ['HACKENV'], "--cwd", os.environ['HACKENV'], "--no-backup", ".hgignore")
    return ret

def truncate(str):
    try:
        str.decode("utf-8")
        str = str[:460].decode("utf-8", "ignore").encode("utf-8")
    except:
        str = str[:460]
    return str

def cleanWorkdir():
    # Find all changed files
    status = subprocess.Popen(["hg", "status", "-R", os.environ['HACKENV'], "-rumad"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    so = status.communicate()[0]

    # Remove anything broken
    for sline in so.split("\n"):
        if sline == "":
            break
        f = sline.split(" ", 1)[1]
        try:
            os.remove(os.path.join(os.environ['HACKENV'], f))
        except:
            pass

    # Get ourselves back up to date
    calldevnull("hg", "up", "-R", os.environ['HACKENV'], "-C")

def transact(log, always_exclusive, args):
    lockf = os.open("lock", os.O_RDWR)

    if not always_exclusive:
        fcntl.flock(lockf, fcntl.LOCK_SH)

        output = callLimit(args, False)

        # Check if we wrote
        status = subprocess.Popen(["hg", "status", "-R", os.environ['HACKENV'], "-rumad"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        so = status.communicate()[0]

    if always_exclusive or so != "":
        # OK, we need to do this exclusively
        if not always_exclusive: fcntl.flock(lockf, fcntl.LOCK_UN)
        fcntl.flock(lockf, fcntl.LOCK_EX)

        # Restore the working directory
        cleanWorkdir()

        # Run again
        output = callLimit(args, True)

        # And commit (or cleanup if blocked by canary)
        if os.path.exists(os.path.join(os.environ['HACKENV'], "canary")):
            calldevnull("hg", "addremove", "-R", os.environ['HACKENV'])
            calldevnull("hg", "commit", "-R", os.environ['HACKENV'], "-m", "<%s> %s" %
                (os.environ['IRC_NICK'], log.encode('string_escape')))
        else:
            cleanWorkdir()

    fcntl.flock(lockf, fcntl.LOCK_UN)
    os.close(lockf)

    output = string.rstrip(output)
    if output == "":
        output = "No output."

    # be safe if the first char is not alphanumeric
    if not re.match("^[A-Za-z0-9_]", output):
        output = "\xe2\x80\x8b" + output

    output = string.replace(string.replace(string.replace(output, "\n", " \\ "), "\x01", "."), "\x00", ".")
    output = truncate(output)
    say(output)

parts = message.split(' ', 1)
command = parts[0]
arg = parts[1] if len(parts) > 1 else ''

if any(os.environ['IRC_NICK'].startswith(ignore) for ignore in ignored_nicks):
    say('Mmmmm... no.')
    sys.exit(1)

if command == 'help' and len(parts) == 1:
    say(help_text)
elif command == 'fetch':
    transact('fetch ' + arg, True, ['lib/fetch', arg])
elif command == 'run':
    transact(arg, False, ['lib/sandbox', 'bash', '-c', arg])
elif command == 'revert':
    transact('revert ' + arg, True, ['lib/revert', arg])
else:
    if arg:
        transact(command + ' ' + arg, False, ['lib/sandbox', command, arg])
    else:
        transact(command, False, ['lib/sandbox', command])
