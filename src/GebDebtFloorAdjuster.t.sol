pragma solidity ^0.6.7;

import "ds-test/test.sol";

import "./GebDebtFloorAdjuster.sol";

contract GebDebtFloorAdjusterTest is DSTest {
    GebDebtFloorAdjuster adjuster;

    function setUp() public {
        adjuster = new GebDebtFloorAdjuster();
    }

    function testFail_basic_sanity() public {
        assertTrue(false);
    }

    function test_basic_sanity() public {
        assertTrue(true);
    }
}
