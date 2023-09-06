#!/bin/sh
TF_IN_AUTOMATION=1 TF_INPUT=0 TF_CLI_ARGS="-auto-approve" terraform ${@}
