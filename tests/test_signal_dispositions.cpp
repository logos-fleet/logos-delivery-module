// What delivery_module does to the HOST PROCESS's signal dispositions, and what
// it must leave alone. `ignoreSigpipeIfUnhandled` in
// src/delivery_module_plugin.cpp records why SIGPIPE is the one disposition
// this module takes, and why it takes it only from a host that has expressed no
// preference of its own; these two cases pin both halves of that.
// See logos-workspace#150.
#include <csignal>

#include <logos_test.h>
#include "delivery_module_plugin.h"
#include "mocks/delivery_module_events_stub.h"

namespace {

using SignalHandler = void (*)(int);

// Saves the process's SIGPIPE disposition for the duration of a test, so one
// test's arrangement cannot leak into the next.
struct SigpipeDisposition {
    SigpipeDisposition() { sigaction(SIGPIPE, nullptr, &saved); }
    ~SigpipeDisposition() { sigaction(SIGPIPE, &saved, nullptr); }

    static void set(SignalHandler handler) {
        struct sigaction sa {};
        sa.sa_handler = handler;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGPIPE, &sa, nullptr);
    }

    static SignalHandler current() {
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
