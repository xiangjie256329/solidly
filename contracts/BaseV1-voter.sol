// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

library Math {
    function min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }
}

interface erc20 {
    function totalSupply() external view returns (uint256);
    function transfer(address recipient, uint amount) external returns (bool);
    function balanceOf(address) external view returns (uint);
    function transferFrom(address sender, address recipient, uint amount) external returns (bool);
    function approve(address spender, uint value) external returns (bool);
}

interface ve {
    function token() external view returns (address);
    function balanceOfNFT(uint) external view returns (uint);
    function isApprovedOrOwner(address, uint) external view returns (bool);
    function ownerOf(uint) external view returns (address);
    function transferFrom(address, address, uint) external;
    function attach(uint tokenId) external;
    function detach(uint tokenId) external;
    function voting(uint tokenId) external;
    function abstain(uint tokenId) external;
}

interface IBaseV1Factory {
    function isPair(address) external view returns (bool);
}

interface IBaseV1Core {
    function claimFees() external returns (uint, uint);
    function tokens() external returns (address, address);
}

interface IBaseV1GaugeFactory {
    function createGauge(address, address, address) external returns (address);
}

interface IBaseV1BribeFactory {
    function createBribe() external returns (address);
}

interface IGauge {
    function notifyRewardAmount(address token, uint amount) external;
    function getReward(address account, address[] memory tokens) external;
    function claimFees() external returns (uint claimed0, uint claimed1);
    function left(address token) external view returns (uint);
}

interface IBribe {
    function _deposit(uint amount, uint tokenId) external;
    function _withdraw(uint amount, uint tokenId) external;
    function getRewardForOwner(uint tokenId, address[] memory tokens) external;
}

interface IMinter {
    function update_period() external returns (uint);
}

contract BaseV1Voter {

    address public immutable _ve; // the ve token that governs these contracts
    address public immutable factory; // the BaseV1Factory
    address internal immutable base; //erc20代币
    address public immutable gaugefactory; //
    address public immutable bribefactory;
    uint internal constant DURATION = 7 days; // rewards are released over 7 days
    address public minter;

    uint public totalWeight; // total voting weight

    address[] public pools; // all pools viable for incentives lp交易对
    mapping(address => address) public gauges; // pool => gauge lp->奖池
    mapping(address => address) public poolForGauge; // gauge => pool 奖池->lp
    mapping(address => address) public bribes; // gauge => bribe 奖池->贿赂
    mapping(address => int256) public weights; // pool => weight lp->权重
    mapping(uint => mapping(address => int256)) public votes; // nft => pool => votes tokenId->lp->投票
    mapping(uint => address[]) public poolVote; // nft => pools tokenId->lp
    mapping(uint => uint) public usedWeights;  // nft => total voting weight of user tokenId->总投票权重
    mapping(address => bool) public isGauge;    //判断地址是否是奖池
    mapping(address => bool) public isWhitelisted; //判断是否是白名单

    event GaugeCreated(address indexed gauge, address creator, address indexed bribe, address indexed pool);
    event Voted(address indexed voter, uint tokenId, int256 weight);
    event Abstained(uint tokenId, int256 weight);
    event Deposit(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event Withdraw(address indexed lp, address indexed gauge, uint tokenId, uint amount);
    event NotifyReward(address indexed sender, address indexed reward, uint amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint amount);
    event Attach(address indexed owner, address indexed gauge, uint tokenId);
    event Detach(address indexed owner, address indexed gauge, uint tokenId);
    event Whitelisted(address indexed whitelister, address indexed token);

    constructor(address __ve, address _factory, address  _gauges, address _bribes) {
        _ve = __ve;
        factory = _factory;
        base = ve(__ve).token();
        gaugefactory = _gauges;
        bribefactory = _bribes;
        minter = msg.sender;
    }

    // simple re-entrancy check
    uint internal _unlocked = 1;
    modifier lock() {
        require(_unlocked == 1);
        _unlocked = 2;
        _;
        _unlocked = 1;
    }

    function initialize(address[] memory _tokens, address _minter) external {
        require(msg.sender == minter); //只有minter可以初始化白名单
        for (uint i = 0; i < _tokens.length; i++) {
            _whitelist(_tokens[i]); //支持去重,不用担心重复添加
        }
        minter = _minter; //顺带可以修改minter移交权限
    }

    function listing_fee() public view returns (uint) {
        return (erc20(base).totalSupply() - erc20(_ve).totalSupply()) / 200; //(总量-锁仓总量)/200
    }

    function reset(uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        _reset(_tokenId);
        ve(_ve).abstain(_tokenId);
    }

    function _reset(uint _tokenId) internal {
        address[] storage _poolVote = poolVote[_tokenId];//先拿到之前投的池子
        uint _poolVoteCnt = _poolVote.length;
        int256 _totalWeight = 0;

        for (uint i = 0; i < _poolVoteCnt; i ++) {
            address _pool = _poolVote[i];
            int256 _votes = votes[_tokenId][_pool];//原来池子对应的投票

            if (_votes != 0) {
                _updateFor(gauges[_pool]);//根据lp拿到奖池地址,然后在改票前更新奖池收益
                weights[_pool] -= _votes;//移除原投票权重
                votes[_tokenId][_pool] -= _votes;//移除原投票
                if (_votes > 0) {//原投票大于0,则可以从贿赂池收取奖励,同时更新总更新权重
                    IBribe(bribes[gauges[_pool]])._withdraw(uint256(_votes), _tokenId);
                    _totalWeight += _votes;
                } else {
                    _totalWeight -= _votes;//原投票小于0,则没有贿赂收益,但总更新权重还是会加上其正值
                }
                emit Abstained(_tokenId, _votes);//链上标记tokenId弃权
            }
        }
        totalWeight -= uint256(_totalWeight);//更新投票总权重
        usedWeights[_tokenId] = 0;//奖tokenId的使用权重置0
        delete poolVote[_tokenId];//删除tokenId的投票lp
    }

    function poke(uint _tokenId) external {//拿走收益再复投?
        address[] memory _poolVote = poolVote[_tokenId];//根据tokenId拿到所有投票的lp池
        uint _poolCnt = _poolVote.length;
        int256[] memory _weights = new int256[](_poolCnt);

        for (uint i = 0; i < _poolCnt; i ++) {
            _weights[i] = votes[_tokenId][_poolVote[i]];//拿到之前的投票权重
        }

        _vote(_tokenId, _poolVote, _weights);
    }

    function _vote(uint _tokenId, address[] memory _poolVote, int256[] memory _weights) internal {
        _reset(_tokenId);//先把tokenId之前投票的收益结算,并清空原投票lp,权重等
        uint _poolCnt = _poolVote.length;
        int256 _weight = int256(ve(_ve).balanceOfNFT(_tokenId));//获取tokenId的最新投票权重,随时间增加,解锁的权重会变多
        int256 _totalVoteWeight = 0;
        int256 _totalWeight = 0;
        int256 _usedWeight = 0;

        for (uint i = 0; i < _poolCnt; i++) {//更新权重累加,负数变正
            _totalVoteWeight += _weights[i] > 0 ? _weights[i] : -_weights[i];
        }

        for (uint i = 0; i < _poolCnt; i++) {
            address _pool = _poolVote[i];
            address _gauge = gauges[_pool];

            if (isGauge[_gauge]) {//如果是奖池就更新
                int256 _poolWeight = _weights[i] * _weight / _totalVoteWeight;
                require(votes[_tokenId][_pool] == 0);//以前没投过,或者清空了
                require(_poolWeight != 0);
                _updateFor(_gauge);//更新奖池

                poolVote[_tokenId].push(_pool);//token

                weights[_pool] += _poolWeight;
                votes[_tokenId][_pool] += _poolWeight;
                if (_poolWeight > 0) {//增加贿赂奖池的总权重,反对票则不减少原有tokenId的权重
                    IBribe(bribes[_gauge])._deposit(uint256(_poolWeight), _tokenId);
                } else {
                    _poolWeight = -_poolWeight;
                }
                _usedWeight += _poolWeight;//更新权重
                _totalWeight += _poolWeight;
                emit Voted(msg.sender, _tokenId, _poolWeight);
            }
        }
        if (_usedWeight > 0) ve(_ve).voting(_tokenId);//标记为已投票
        totalWeight += uint256(_totalWeight); //更新合约totalWeight
        usedWeights[_tokenId] = uint256(_usedWeight);//更新合约tokenId的已使用权重
    }

    //一个nft可以投多个池子
    function vote(uint tokenId, address[] calldata _poolVote, int256[] calldata _weights) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, tokenId));//先判断msg.sender是否是tokenId的owner或approver
        require(_poolVote.length == _weights.length);
        _vote(tokenId, _poolVote, _weights);
    }

    function whitelist(address _token, uint _tokenId) public {//给token添加白名单,需要tokenId里面锁仓的平台币足够多
        if (_tokenId > 0) {
            require(msg.sender == ve(_ve).ownerOf(_tokenId));
            require(ve(_ve).balanceOfNFT(_tokenId) > listing_fee());//如果tokenId大于0,则需要该tokenId的权重大于1/200的流动量
        } else {
            _safeTransferFrom(base, msg.sender, minter, listing_fee());//如果没有这么多的权重,直接给minter这么多平台币也是可以的
        }

        _whitelist(_token);
    }

    function _whitelist(address _token) internal {
        require(!isWhitelisted[_token]);
        isWhitelisted[_token] = true;//标记一下
        emit Whitelisted(msg.sender, _token);
    }

    function createGauge(address _pool) external returns (address) {//创建奖池
        require(gauges[_pool] == address(0x0), "exists");
        require(IBaseV1Factory(factory).isPair(_pool), "!_pool");//奖池要先存在
        (address tokenA, address tokenB) = IBaseV1Core(_pool).tokens();//获取tokenA和tokenB
        require(isWhitelisted[tokenA] && isWhitelisted[tokenB], "!whitelisted");//tokenA和tokenB必须在白名单
        address _bribe = IBaseV1BribeFactory(bribefactory).createBribe();//创建贿赂
        address _gauge = IBaseV1GaugeFactory(gaugefactory).createGauge(_pool, _bribe, _ve);//创建奖池
        erc20(base).approve(_gauge, type(uint).max);
        bribes[_gauge] = _bribe;//更新数据
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        _updateFor(_gauge);
        pools.push(_pool);
        emit GaugeCreated(_gauge, msg.sender, _bribe, _pool);//链上标记
        return _gauge;
    }

    function attachTokenToGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) ve(_ve).attach(tokenId);
        emit Attach(account, msg.sender, tokenId);
    }

    function emitDeposit(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Deposit(account, msg.sender, tokenId, amount);
    }

    function detachTokenFromGauge(uint tokenId, address account) external {
        require(isGauge[msg.sender]);
        if (tokenId > 0) ve(_ve).detach(tokenId);
        emit Detach(account, msg.sender, tokenId);
    }

    function emitWithdraw(uint tokenId, address account, uint amount) external {
        require(isGauge[msg.sender]);
        emit Withdraw(account, msg.sender, tokenId, amount);
    }

    function length() external view returns (uint) {
        return pools.length;
    }

    uint internal index;
    mapping(address => uint) internal supplyIndex;
    mapping(address => uint) public claimable;//总提现

    function notifyRewardAmount(uint amount) external {
        _safeTransferFrom(base, msg.sender, address(this), amount); // transfer the distro in
        uint256 _ratio = amount * 1e18 / totalWeight; // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }
        emit NotifyReward(msg.sender, base, amount);
    }

    function updateFor(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            _updateFor(_gauges[i]);
        }
    }

    function updateForRange(uint start, uint end) public {
        for (uint i = start; i < end; i++) {
            _updateFor(gauges[pools[i]]);
        }
    }

    function updateAll() external {
        updateForRange(0, pools.length);
    }

    function updateGauge(address _gauge) external {
        _updateFor(_gauge);
    }

    function _updateFor(address _gauge) internal {//更新奖池可提现收益
        address _pool = poolForGauge[_gauge];//再通过奖池拿回lp
        int256 _supplied = weights[_pool];//根据lp拿到总权重
        if (_supplied > 0) {
            uint _supplyIndex = supplyIndex[_gauge];//拿到奖池的下标
            uint _index = index; // get global index0 for accumulated distro //获取最新下标
            supplyIndex[_gauge] = _index; // update _gauge current position to global position //并设置给奖池
            uint _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued //计算下标差
            if (_delta > 0) {//根据权重和下标差增加总提现,相当于用户如果想改票,则把之前票的收益先给lp更新一下
                uint _share = uint(_supplied) * _delta / 1e18; // add accrued difference for each supplied token
                claimable[_gauge] += _share;
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    function claimRewards(address[] memory _gauges, address[][] memory _tokens) external {//提取奖励
        for (uint i = 0; i < _gauges.length; i++) {
            IGauge(_gauges[i]).getReward(msg.sender, _tokens[i]);
        }
    }

    function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint _tokenId) external {//提取贿赂
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _bribes.length; i++) {
            IBribe(_bribes[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function claimFees(address[] memory _fees, address[][] memory _tokens, uint _tokenId) external {
        require(ve(_ve).isApprovedOrOwner(msg.sender, _tokenId));
        for (uint i = 0; i < _fees.length; i++) {
            IBribe(_fees[i]).getRewardForOwner(_tokenId, _tokens[i]);
        }
    }

    function distributeFees(address[] memory _gauges) external {
        for (uint i = 0; i < _gauges.length; i++) {
            IGauge(_gauges[i]).claimFees();
        }
    }

    function distribute(address _gauge) public lock {
        IMinter(minter).update_period();//
        _updateFor(_gauge);//更新奖池
        uint _claimable = claimable[_gauge];
        if (_claimable > IGauge(_gauge).left(base) && _claimable / DURATION > 0) {
            claimable[_gauge] = 0;
            IGauge(_gauge).notifyRewardAmount(base, _claimable);
            emit DistributeReward(msg.sender, _gauge, _claimable);
        }
    }

    function distro() external {
        distribute(0, pools.length);
    }

    function distribute() external {
        distribute(0, pools.length);
    }

    function distribute(uint start, uint finish) public {
        for (uint x = start; x < finish; x++) {
            distribute(gauges[pools[x]]);
        }
    }

    function distribute(address[] memory _gauges) external {
        for (uint x = 0; x < _gauges.length; x++) {
            distribute(_gauges[x]);
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) =
        token.call(abi.encodeWithSelector(erc20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }
}
