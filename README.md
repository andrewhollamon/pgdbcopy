# POSTGRESQL DB COPY TOOL

## USAGE

```
./pgdbcopy.sh --dsn YOURDB.rds.amazonaws.com:5432/YOURDB --ruser REMOTEUSER --rpass REMOTEPASSWORD --luser LOCALUSER --lpass LOCALPASS --schema YOURSCHEMA --tables TABLE1 TABLE2 TABLE3 ...
```

Where all the capitalized words should be replaced with your values.

## WARNINGS AND ASSUMPTIONS
- This script currently will leave actual passwords passed into the command line in plaintext in `ps aux` or `/proc/<pid>/cmdline` while the script is running. It will also leave these passwords in plaintext in your shell history. Next update to this software will move the user/passwords into a `.pgpass` file.
- If you're running your local postgresdb in "no authentication" mode, then this script won't be able to connect. Even with `listen_addresses = 'localhost'` uncommented in your `postgresql.conf`, there's a vulnerability in that any locally running script, program, application, or malware will be able to connect and query data. This is too high of a risk for my current environment.
- You'll need to have created the local schemas yourself, this script will not create a schema, it expects it to be created already.
- This does NOT handle referential integrity at this time. The tables will be created in the local DB without any referential integrity. This is to avoid the complexity of coding for a potentially cyclic graph of relationships. If you need that in your local database, you'd need to find a more complex tool.

### SETTING UP LOCAL PASSWORD

There are many online resources to assist with this, but the general set of tasks is:

- Make sure your `postgresql.conf` file has `listen_addresses = 'localhost'` uncommented and active
- Modify your `pg_hba.conf` file with the following lines, replace `trust` with `scram-sha-256`
    - `local   all             all                                     trust`
    - `host    all             all             127.0.0.1/32            trust`
    - `host    all             all             ::1/128                 trust`
    - Each value of `trust` above should be replaced with `scram-sha-256`
- Do NOT restart your local postgres yet
- Run this with psql or your db tool:
    - `ALTER USER your_username WITH PASSWORD 'your_password';`
    - make sure this completes successfully before going on 
- Restart postgresql with `brew services restart postgresql@18` or whatever means you normally use (and with the correct postgresql version number)
- Update the connection strings in your DB tool with `your_password` from above

## OVERVIEW

I often need to work with reference data in PostgreSQL DB in AWS.

There is one challenge though with these remote AWS databases, we dont have any personal schemas, or any other way to create temp tables that are persistent beyond the session, and can be accessed with tools like DataGrip, etc.

So one alternative which is to stand up a local postgres db on the local machine, copy the tables over, and do exploratory work there, where I have privs to create temp tables and do whatever I want.

But this is a pain to do each time to make sure I have current data.

This tool automates this process.

It connects to the remote DB, creates CREATE TABLE scripts with PKs, Constraints and Indexes. 

It does NOT copy over referential integrity relationships.

It then dumps the table contents to a CSV on the local laptop.

Both of these files are created in the `exports` folder in the script directory.

For each table specified, it then drops all indexes, PKs and constraints, then renames the table to table_backup.

And then re-creates the table via SQL scripts (in case the structure has changed), and bulk loads the data from CSV.

This turns a 10-15 minute manual process, into a 90 second one-shot script run.

Note that this was started by Claude Code, with a number of hand edits by myself where it got things wrong.
