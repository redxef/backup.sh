# backup.sh

Create incremental, indexed archives with tar.

# Description

Tar already provides a way to create incremental backups natively.
But there is no way to branch backups and make multiple incremental backups
from a level 0 dump. This actually only involves copying the index file
and using this from there on. The aim of this little script is to automate the
management of these index files. Maybe you want to create level 0 backups yearly,
incremental ones every month, and weekly backups from the base monthly backup?
This script aims to make this easier.

# Example

```shell
git clone https://github.com/redxef/backup.sh
cd backup.sh
mkdir test idx
touch test/a.txt back_exclude.txt

# backup initial modifications
./backup.sh archive test test0.tar.bz2 test.snar
echo 'HELLO!' > test/a.txt
./backup.sh archive test test1.tar.bz2 test.snar

# create a branch week1 backup is test.snar, week2 backup is test-b0.snar?
./backup.sh branch test.snar test-b0.snar

# modifications of week1 with backup
echo 'hello!' > test/a.txt
./backup.sh archive test test2.tar.bz2 test.snar

# modifications of week2 with backup
echo 'hello world!' > test/a.txt
./backup.sh archive test test2_.tar.bz2 test-b0.snar


# oops we lost everything in test/:
rm test/a.txt

# restore state of week2
./backup.sh restore test2_.tar.bz2 test

# or

# restore state of week1
./backup.sh restore test2.tar.bz2 test

```

# Automatically managing backups.

It is also possible to create a configuration file which will be read
when the program runs the sub-program managed_cycle, without any
arguments (\``./backup.sh managed_cycle`'). According to rules in
the \``rules.conf`' file backups will be automatically generated, there
is as of yet no way to delete old backups, this will need to be done
manually.
