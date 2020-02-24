# backup.sh

Create incremental, index archives with tar.

# Description

Tar already provides a way to create incremental backups natively.
But there is no way to branch backups and make multiple incremental backups
from a level 0 dump. This actually only involves copying the the index file
and using this from there on. The aim of this little script is to automate the
management of these index files.

# Example

```shell
git clone https://github.com/redxef/backup.sh
cd backup.sh
mkdir test
touch test/a.txt

# backup initial modifications up
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
