# POSTGRESQL DB COPY TOOL

## USAGE

```
./pgdbcopy.sh --dsn YOURDB.rds.amazonaws.com:5432/YOURDB --user YOURUSERNAME --pass YOURPASSWORD --schema YOURSCHEMA --tables TABLE1 TABLE2 TABLE3 ...
```

Where all the capitalized words should be replaced with your values.

WARNING: This script assumes your local postgresql db is running without authentication turned on, ie no user/pass. Make sure you've got it limited to localhost connections only! (`listen_addresses = 'localhost'` should be uncommented in your `postgresql.conf`)

WARNING: You'll need to have created the local schemas yourself, this script will not create a schema, it expects it to be created already.

## CAUTION

This does NOT handle referential integrity at this time.

The tables will be created in the local DB without any referential integrity.

This is to avoid the complexity of coding for a potentially cyclic graph of relationships. If you need that in your local database, you'd need to find a more complex tool.

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
