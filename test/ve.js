const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ve", function () {
  let token;
  let ve_underlying;
  let ve;
  let owner;
  let ve_underlying_amount = ethers.BigNumber.from("1000000000000000000000");//1000
  let unit = ethers.BigNumber.from("1000000000000000000");
  console.log("111");

  beforeEach(async function () {
    [owner] = await ethers.getSigners();
    token = await ethers.getContractFactory("Token");
    ve_underlying = await token.deploy("VE", "VE", 18, owner.address);
    await ve_underlying.deployed();
    await ve_underlying.mint(owner.address, ve_underlying_amount);
    vecontract = await ethers.getContractFactory("contracts/ve.sol:ve");
    ve = await vecontract.deploy(ve_underlying.address);
    await ve.deployed();
  });

  it("create lock", async function () {
    await ve_underlying.approve(ve.address, ve_underlying_amount);
    const lockDuration = 7 * 24 * 3600; // 1 week 最少1周,设置0会报错

    // Balance should be zero before and 1 after creating the lock
    expect(await ve.balanceOf(owner.address)).to.equal(0);//有多少个nft
    await ve.create_lock(ve_underlying_amount, lockDuration);
    expect(await ve.ownerOf(1)).to.equal(owner.address);
    expect(await ve.balanceOf(owner.address)).to.equal(1);
    const balanceOfNFT = await ve.balanceOfNFT(1);
    console.log("balanceOfNFT:",balanceOfNFT/unit);//uint unlock_time = (block.timestamp + _lock_duration) / WEEK * WEEK;//所以如果指定锁仓时间是一周的话,通常是没有一周的
  });

  it("create lock outside allowed zones", async function () {//最大就4年,超过了会报错
    await ve_underlying.approve(ve.address, ve_underlying_amount);
    const oneWeek = 7 * 24 * 3600;
    const fourYears = 4 * 365 * 24 * 3600;
    await expect(ve.create_lock(ve_underlying_amount, fourYears + oneWeek)).to.be.reverted;
  });

  it("Withdraw", async function () {
    let half_ve_underlying_amount = ve_underlying_amount.div(2);
    await ve_underlying.approve(ve.address, ve_underlying_amount);
    const lockDuration = 7 * 24 * 3600; // 1 week
    
    await ve.create_lock(half_ve_underlying_amount, lockDuration);
    let balanceOfNFT = await ve.balanceOfNFT(1);
    let balance = await ve.balanceOf(owner.address);
    console.log("create_lock:balanceOfNFT:%d,balance:%d",balanceOfNFT/unit,balance/unit);

    let uri = await ve.tokenURI(1)
    //console.log("uri:",uri); //一长串
    // Try withdraw early
    const tokenId = 1;
    await expect(ve.withdraw(tokenId)).to.be.reverted; //不能提前取现

    console.log("123");
    await ve.create_lock(half_ve_underlying_amount, lockDuration);
    //await ve.increase_amount(1,half_ve_underlying_amount);
    console.log("456");

    balanceOfNFT = await ve.balanceOfNFT(1);
    balance = await ve.balanceOf(owner.address);
    console.log("lock_end:balanceOfNFT:%d,balance:%d",balanceOfNFT/unit,balance/unit);
    // Now try withdraw after the time has expired
    ethers.provider.send("evm_increaseTime", [lockDuration-3*86400]);
    ethers.provider.send("evm_mine"); // mine the next block

    await ve.withdraw(tokenId);

    expect(await ve_underlying.balance(owner.address)).to.equal(ve_underlying_amount);
    // Check that the NFT is burnt
    expect(await ve.balanceOfNFT(tokenId)).to.equal(0);
    expect(await ve.ownerOf(tokenId)).to.equal(ethers.constants.AddressZero);
  });

  it("check tokenURI calls", async function () {//如果提现了,则没有tokenURI了
    // tokenURI should not work for non-existent token ids
    //await expect(ve.tokenURI(999)).to.be.reverted;
    await ve_underlying.approve(ve.address, ve_underlying_amount);
    const lockDuration = 7 * 24 * 3600; // 1 week
    await ve.create_lock(ve_underlying_amount, lockDuration);

    const tokenId = 1;
    ethers.provider.send("evm_increaseTime", [lockDuration]);
    ethers.provider.send("evm_mine"); // mine the next block

    // // Just check that this doesn't revert
    await ve.tokenURI(tokenId);

    // // Withdraw, which destroys the NFT
    await ve.withdraw(tokenId);

    // // tokenURI should not work for this anymore as the NFT is burnt
    await expect(ve.tokenURI(tokenId)).to.be.reverted;
  });

  it("Confirm supportsInterface works with expected interfaces", async function () {
    // Check that it supports all the expected interfaces.
    const ERC165_INTERFACE_ID = 0x01ffc9a7;
    const ERC721_INTERFACE_ID = 0x80ac58cd;
    const ERC721_METADATA_INTERFACE_ID = 0x5b5e139f;

    expect(await ve.supportsInterface(ERC165_INTERFACE_ID)).to.be.true;
    expect(await ve.supportsInterface(ERC721_INTERFACE_ID)).to.be.true;
    expect(await ve.supportsInterface(ERC721_METADATA_INTERFACE_ID)).to.be.true;
  });

  it("Check supportsInterface handles unsupported interfaces correctly", async function () {
    const ERC721_FAKE = 0x780e9d61;
    expect(await ve.supportsInterface(ERC721_FAKE)).to.be.false;
  });
});
