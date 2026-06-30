// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

abstract contract Initializable {
    bool private _initialized;

    modifier initializer() {
        require(!_initialized, "Already initialized");
        _initialized = true;
        _;
    }

    function _isInitialized() internal view returns (bool) {
        return _initialized;
    }
}
