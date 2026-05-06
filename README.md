# POSTGRESQL DB COPY TOOL

Much of the work I do involves querying, exploring, and modifying data in a postgres db in AWS by my employer.

There is one big challenge though with these databases, we dont have any personal schemas, or any other way to create temp tables that are persistent beyond the session, and can be accessed with tools like DataGrip, etc.

So one alternative which we use is to stand up a local postgres db on the local machine, copy the tables over, and do exploratory work there, where I have privs to create temp tables and do whatever I want.

But this is a pain to do each time to make sure I have current data.

This tool automates this process.

It connects to the remote DB, creates CREATE TABLE scripts with PKs, Constraints and Indexes.

It then dumps the table contents to a CSV on the local laptop.

Both of these files are created in the `exports` folder in the script directory.

For each table specified, it then drops all indexes, PKs and constraints, then renames the table to table_backup.

And then re-creates the table via SQL scripts (in case the structure has changed), and bulk loads the data from CSV.

This turns a 10-15 minute manual process, into a 90 second one-shot script run.

Note that this was mostly developed by Claude Code, with a number of hand edits by myself where it got things wrong.
