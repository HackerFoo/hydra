#pragma once

#include "store-api.hh"
#include "derivations.hh"

struct RemoteResult
{
    enum {
        rrSuccess = 0,
        rrPermanentFailure = 1,
        rrTimedOut = 2,
        rrMiscFailure = 3
    } status = rrMiscFailure;
    std::string errorMsg;
    time_t startTime = 0, stopTime = 0;
};

void buildRemote(std::shared_ptr<nix::StoreAPI> store,
    const std::string & sshName, const std::string & sshKey,
    const nix::Path & drvPath, const nix::Derivation & drv,
    const nix::Path & logDir, RemoteResult & result);
