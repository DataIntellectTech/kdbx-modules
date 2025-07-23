# Data Intellect KDB-X Module Style Guide

This document outlines the style rules to follow when contributing q code to
this repository. The goal of these guidelines is to increase readability and
create consistency.

## Whitespace

Avoid excessive & unnecessary whitespace.

Indentation should be used to indicate control flow - use 2 spaces for
indentation. The body of a function should be indented by 2 spaces from function
definition, and body of any multi-line `if` statement should be indented by
further 2 spaces and so on.

Avoid any trailing whitespace.

## Comments

Focus on why, not what the code is doing - describe business logic and purpose
of code.

In-line comments are permissible for short lines defining only variables; in
other cases, comments should be on line preceding the code they describe.

Where in-line comments are used, give them the same alignment (using spaces).

Comments should start with `/` followed by a space and then start with
lowercase letter (unless using a proper noun).

## Naming

All functions and variables should use all lowercase names - no camelCase and no
underscores.

For local variables that will only be used close to their definitions, shorter
names are prefered; for global variables or variables that will be used far from
their definitions, longer, more descriptive names are prefered.

Don't use any q reserved names.

## Functions

Function declaration should be on it's own line with just parameters.

Every other line of the function should contain a single statement and be
terminated by a semi-colon. Closing brace of function should also be terminated
by a semi-colon.

Use of explicit return (`:`) is encouraged.

Short anonymous lambdas with implicit parameters are permitted, but longer
lambdas or those with explicit parameters should be defined as named functions.

## Conditionals and execution control

Avoid 'block' statements within conditionals - consider defining separate
functions for each branch of conditional instead. Another good alternative is
using a dictionary or namespace e.g.

```q
.eg.weekend:{[x;y]...};
.eg.weekday:{[x;y]...};

.eg[`weekend`weekday 1<.z.d mod 7][x;y]
```

## q-sql

Simple q-sql statements, such as:

```q
select from trades where sym=`AAPL
```

should be written in line, just like normal code. However for more complex q-sql
- where there are multiple select, by and where clauses - the statement should
be multilined. For example:

```q
select
  avgspread:avg (ask-bid),
  twas:((next time) - time) wavg (ask-bid),
  avgsize:avg (asize,bsize),
  avgduration:"t"$avg ((next time)-time)
by
  sym,
  src
from
  quote
where
  sym in syms,
  time within(st;et)
```

Avoid functional form of q-sql unless totally necessary. If it is necessary,
incude the regular q-sql statement as a comment.

## Parentheses and brackets

Less is more - avoid excessive use of parentheses and brackets.

## Miscellaneous

Do not use the datetime type (`"z"`) as it is considered deprecated. Use
timestamps (`"p"`) instead.

End all lines with semicolons (`;`).

Avoid the use of global assign (`::`) unless totally necessary.

Log early and log often.

Do not use the `do`, `while`, and `for` functions. In 99.99% of cases if you're
using these you should be using an iterator instead.

Do not use windows carriage returns `^M` in q files. You can fix this by using
dos2unix.

Unless it is unavoidable lines of code should not exceed 150 characters.
