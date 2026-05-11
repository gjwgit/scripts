########################################################################
#
# Generic Makefile for Common Variables
#
# Time-stamp: <Tuesday 2026-05-12 08:50:47 +1000 Graham Williams>
#
# Copyright (c) Graham.Williams@togaware.com
#
# License: Creative Commons Attribution-ShareAlike 4.0 International.
#
########################################################################

# This makefile defines common project specific variables that fine
# tune the other makefiles that you will find in this folder. The
# intention is that we can determine many of a projects variables
# autoatically to then use these across the other makefiles in this
# folder.  The makefiles here will each `include` this common.mk. The
# other makefiles in this folder are expected to be included into a
# Makefile in the project root folder so that the paths all work
# okay expecting to be in the root of the project.

# App is often the current directory name.
#
# App version numbers
#   Major release
#   Minor update
#   Trivial update or bug fix
#   Release number of iOs and Android

APP=$(shell pwd | xargs basename)
VER=$(shell egrep '^version:' pubspec.yaml | cut -d' ' -f2 | cut -d'+' -f1)
DATE=$(shell date +%Y-%m-%d)

# Producer
#
# 20260512 gjw Record here whether SII or TOGAWARE is the producer.
#
# Set the producer appropriately or else leave it empty.

PRODUCER := $(shell grep -q "Togaware Pty Ltd" license.dart && echo TOGAWARE || echo "")
