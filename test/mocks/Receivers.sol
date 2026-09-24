// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency} from "v4-core/src/types/Currency.sol";
import {PvPadHook} from "../../src/PvPadHook.sol";

/// @dev A receiver that only logs: fits in the 2300-gas push, like a Safe.
contract LoggingReceiver {
    event Received(address from, uint256 amount);

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }
}

/// @dev A receiver that writes storage: too expensive for the 2300-gas push, fine with full gas.
contract StoringReceiver {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }

    function pull(PvPadHook hook, Currency currency, address to) external {
        hook.withdraw(currency, to);
    }
}

/// @dev A receiver that refuses every payment.
contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }

    function pull(PvPadHook hook, Currency currency, address to) external {
        hook.withdraw(currency, to);
    }
}

/// @dev A beneficiary that tries to re-enter the hook whenever it is paid.
contract ReentrantBeneficiary {
    PvPadHook public immutable hook;
    Currency public immutable currency;
    uint256 public attempts;
    bool public reentered;

    constructor(PvPadHook hook_, Currency currency_) {
        hook = hook_;
        currency = currency_;
    }

    receive() external payable {
        attempts++;
        // Any state change inside the hook while it pays us would be a reentrancy hole.
        hook.withdraw(currency, address(this));
        reentered = true;
    }

    function pull(address to) external {
        hook.withdraw(currency, to);
    }
}

/// @dev A beneficiary that consumes all the gas it is given.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}
