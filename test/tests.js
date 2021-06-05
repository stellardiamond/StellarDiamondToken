const StellarDiamond = artifacts.require('StellarDiamond');

contract("StellarDiamond", accounts => {

    it("should put total supply in sender account", async() => {
        const instance = await StellarDiamond.deployed();
        const balance = await instance.balanceOf(tx.origin);
        assert.equal(balance.valueOf(), instance.totalSupply());
    });
});