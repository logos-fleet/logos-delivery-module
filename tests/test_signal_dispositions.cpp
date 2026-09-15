// What delivery_module does to the HOST PROCESS's signal dispositions, and what
// it must leave alone. See logos-workspace#150.
//
// Loading this module used to arm Nim's own handler for SIGSEGV, SIGBUS,
// SIGABRT, SIGFPE, SIGILL and SIGINT -- process-wide, for faults with nothing to
// do with delivery -- and that handler's first statement is a GC allocation, so
// a fault it could not allocate through re-entered it until the stack guard
// page. The library is now built with `--define:noSignalHandler`
// (nix/no-nim-signal-handler.nix), which takes ALL of those with it, SIGPIPE
// included.
//
// SIGPIPE is the one that comes back, and deliberately. chronos ignores it too,
// in `globalInit()`, so the steady state is the same -- but that runs when a
// dispatcher is first created, i.e. when the node starts, whereas Nim's ran at
// NimMain. These two cases pin the window in between, and pin it without
// depending on which chronos platform branch a target compiles. It is not a
// theoretical window: chronos passes MSG_NOSIGNAL on every send and Nim defines
// MSG_NOSIGNAL as 0 on Darwin, so a write to a peer that has gone away really
// does raise SIGPIPE there, and its default action kills the process.
//
// Ignoring SIGPIPE is not the same kind of act as owning SIGSEGV. POSIX gives
// the caller EPIPE instead, nothing is hidden, and it is what every networking
// library in a shared process does. A host that has made its own choice keeps
// it: only SIG_DFL is replaced.
#include <csignal>

#include <logos_test.h>
#include "delivery_module_plugin.h"
#include "mocks/delivery_module_events_stub.h"

namespace {

struct SigpipeDisposition {
    SigpipeDisposition() { sigaction(SIGPIPE, nullptr, &saved); }
    ~SigpipeDisposition() { sigaction(SIGPIPE, &saved, nullptr); }

    static void set(void (*handler)(int)) {
        struct sigaction sa {};
        sa.sa_handler = handler;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPIPE, &sa, nullptr);
    }

    static void (*current())(int) {
        struct sigaction sa {};
        sigaction(SIGPIPE, nullptr, &sa);
        return sa.sa_handler;
    }

    struct sigaction saved {};
};

void hostSigpipeHandler(int) {}

} // namespace

LOGOS_TEST(constructing_the_module_ignores_an_unhandled_SIGPIPE) {
    auto t = LogosTestContext("delivery_module");
    SigpipeDisposition restore;
    SigpipeDisposition::set(SIG_DFL);

    DeliveryModuleImpl impl;

    LOGOS_ASSERT(SigpipeDisposition::current() == SIG_IGN);
}

LOGOS_TEST(constructing_the_module_leaves_the_hosts_own_SIGPIPE_choice_alone) {
    auto t = LogosTestContext("delivery_module");
    SigpipeDisposition restore;
    SigpipeDisposition::set(hostSigpipeHandler);

    DeliveryModuleImpl impl;

    LOGOS_ASSERT(SigpipeDisposition::current() == hostSigpipeHandler);
}
