pragma solidity 0.6.7;

abstract contract OracleRelayerLike {
    function redemptionPrice() virtual public returns (uint256);
}

contract DebtFloorAdjuster {
    // --- Auth ---
    mapping (address => uint) public authorizedAccounts;
    function addAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 1;
        emit AddAuthorization(account);
    }
    function removeAuthorization(address account) virtual external isAuthorized {
        authorizedAccounts[account] = 0;
        emit RemoveAuthorization(account);
    }
    modifier isAuthorized {
        require(authorizedAccounts[msg.sender] == 1, "DebtFloorAdjuster/account-not-authorized");
        _;
    }

    // --- Variables ---
    mapping(bytes32 => uint256) public floorTargetValues;

    OracleRelayerLike           public oracleRelayer;

    // --- Events ---
    event AddAuthorization(address account);
    event RemoveAuthorization(address account);
    event ModifyParameters(bytes32 parameter, address addr);

    constructor(address oracleRelayer_) public {
        require(oracleRelayer_ != address(0), "DebtFloorAdjuster/null-oracle-relayer");
        oracleRelayer = OracleRelayerLike(oracleRelayer_);
        oracleRelayer.redemptionPrice();
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
    }

    // --- Administration ---
    
}
