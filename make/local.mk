########################################################################
#
# Generic Makefile for Local Variables
#
# Time-stamp: <Tuesday 2026-05-12 08:46:46 +1000 Graham Williams>
#
# Copyright (c) Graham.Williams@togaware.com
#
# License: Creative Commons Attribution-ShareAlike 4.0 International.
#
########################################################################

# This makefile defines project specific variables that fine tune the
# oher makefiles that you will find in this folder. The intention is
# that a project will have it's own `local.mk` in the root folder of
# the project and the makefiles here will each `include` that
# local.mk. The other makefiles in this folder are expected to be
# included into a Makefile in the project root folder so that the
# paths all work okay.
#
# The variables defined here do not have values that can be
# automatically determined. They go into common.mk
