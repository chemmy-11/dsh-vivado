# dsh-vivado -- marker helper for detached (or any) batch builds.
#
# Why a marker file: a detached build cannot return a tool result, and a session background job
# dies with the turn (measured 2026-10-24: a synthesis launched at 21:02 was gone after the next
# user message). So the build writes its own state to a file and the agent only reads that file.
#
# Usage (the status path is already exported by tools\vivado-run.ps1):
#
#   source <kit>/templates/build-markers.tcl
#   kit_mark BUILD_START "create_project"
#   ... workflow order: impl gets its own checkpoint from synth ...
#   kit_mark SYNTH_OK "pre_impl_debug.dcp written"
#   kit_mark IMPL_OK "timing met"
#
# Judge progress by these lines, never by a tool result -- there is none. A missing marker after
# the expected window means "still running, or died", not "success".
#
# Vocabulary the persona and docs use: BUILD_START / SYNTH_OK / IMPL_OK / BUILD_FAILED
# (tools\vivado-run.ps1 additionally appends BUILD_EXIT=<rc> itself).
#
# Windows PowerShell 5.1 note: nothing here is shell-specific -- pass the status path through
# the KIT_STATUS_FILE environment variable and the same Tcl works from cmd, pwsh or bash.

proc kit_mark {tag {detail ""}} {
    set path "build_status.txt"
    if {[info exists ::env(KIT_STATUS_FILE)] && $::env(KIT_STATUS_FILE) ne ""} {
        set path $::env(KIT_STATUS_FILE)
    }
    if {[catch {
        set fh [open $path a]
        puts $fh "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $tag $detail"
        close $fh
    } err]} {
        puts "KIT_MARK_FAILED $tag $err"
        return 0
    }
    puts "KIT_MARK $tag $detail"
    return 1
}

proc kit_fail {detail {code 1}} {
    kit_mark BUILD_FAILED $detail
    return -code error -errorcode $code $detail
}
