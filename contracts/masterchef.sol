// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./n2drewards.sol";
import "./n2drpay.sol";

/**
 * @title N2DMasterChefV1
 * @dev Contrato para gestionar staking y recompensas en el protocolo DeFi N2D.
 */
contract N2DMasterChefV1 is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Estructura de datos para almacenar información del usuario en cada pool.
    struct UserInfo {
        uint256 amount;         // Cantidad de tokens staked por el usuario.
        uint256 pendingReward;  // Recompensas pendientes para el usuario.
    }

    // Estructura de datos para almacenar información de cada pool.
    struct PoolInfo {
        IERC20 lpToken;         // Token LP asociado al pool.
        uint256 allocPoint;     // Puntos de asignación del pool.
        uint256 lastRewardBlock;// Último bloque en el que se otorgaron recompensas.
        uint256 rewardTokenPerShare;  // Recompensa por token LP acumulada.
    }

    // Contratos relacionados
    N2DRewards public n2dr;    // Contrato de recompensas N2D.
    N2DRPay public n2drpay;    // Contrato de pagos N2D.

    // Dirección del desarrollador
    address public dev;

    // Recompensa por bloque
    uint256 public n2drPerBlock;

    // Mapeo para almacenar información del usuario en cada pool
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Array para almacenar información de cada pool
    PoolInfo[] public poolInfo;

    // Variables para el control de la asignación total
    uint256 public totalAllocation = 0;
    uint256 public startBlock;
    uint256 public BONUS_MULTIPLIER;

    // Eventos
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    /**
     * @dev Constructor del contrato.
     * @param _n2dr Contrato de recompensas N2D.
     * @param _n2drpay Contrato de pagos N2D.
     * @param _dev Dirección del desarrollador.
     * @param _n2drPerBlock Recompensa por bloque para el token N2DR.
     * @param _startBlock Bloque de inicio.
     * @param _multiplier Multiplicador de bonificación.
     */
    constructor(
        N2DRewards _n2dr,
        N2DRPay _n2drpay,
        address _dev,
        uint256 _n2drPerBlock,
        uint256 _startBlock,
        uint256 _multiplier
    ) Ownable() ReentrancyGuard() {
        n2dr = _n2dr;
        n2drpay = _n2drpay;
        dev = _dev;
        n2drPerBlock = _n2drPerBlock;
        startBlock = _startBlock;
        BONUS_MULTIPLIER = _multiplier;

        // Crear el primer pool al inicializar el contrato
        poolInfo.push(
            PoolInfo({
                lpToken: _n2dr,
                allocPoint: 1000,
                lastRewardBlock: _startBlock,
                rewardTokenPerShare: 0
            })
        );
        totalAllocation = 1000;
    }

    /**
     * @dev Modificador para validar que el ID del pool sea válido.
     * @param _pid ID del pool.
     */
    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "Pool Id Invalid");
        _;
    }

    /**
     * @dev Obtiene información de un pool específico.
     * @param _pid ID del pool.
     * @return lpToken Dirección del token LP del pool.
     * @return allocPoint Puntos de asignación del pool.
     * @return lastRewardBlock Último bloque de recompensa.
     * @return rewardTokenPerShare Recompensa por token LP acumulada.
     */
    function getPoolInfo(uint256 _pid)
        public
        view
        returns (
            address lpToken,
            uint256 allocPoint,
            uint256 lastRewardBlock,
            uint256 rewardTokenPerShare
        )
    {
        return (
            address(poolInfo[_pid].lpToken),
            poolInfo[_pid].allocPoint,
            poolInfo[_pid].lastRewardBlock,
            poolInfo[_pid].rewardTokenPerShare
        );
    }

    /**
     * @dev Devuelve la longitud (número de pools) del contrato.
     * @return Número de pools.
     */
    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    /**
     * @dev Obtiene el multiplicador de bonificación para un rango de bloques.
     * @param _from Bloque de inicio.
     * @param _to Bloque de fin.
     * @return Multiplicador de bonificación.
     */
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    /**
     * @dev Actualiza el multiplicador de bonificación (soloOwner).
     * @param multiplierNumber Nuevo multiplicador de bonificación.
     */
    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    /**
     * @dev Verifica si ya existe un pool con el token LP dado.
     * @param _lpToken Token LP a verificar.
     */
    function checkPoolDuplicate(IERC20 _lpToken) public view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "Pool Already Exists");
        }
    }

    /**
     * @dev Actualiza el pool de staking principal.
     * Distribuye puntos de asignación a los demás pools de staking.
     */
    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocation = totalAllocation.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    /**
     * @dev Agrega un nuevo pool de staking (soloOwner).
     * @param _allocPoint Puntos de asignación para el nuevo pool.
     * @param _lpToken Token LP asociado al nuevo pool.
     * @param _withUpdate Si se debe actualizar la información de los pools existentes antes de agregar el nuevo pool.
     */
    function add(uint256 _allocPoint, IERC20 _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        checkPoolDuplicate(_lpToken);
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocation = totalAllocation.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                rewardTokenPerShare: 0
            })
        );
        updateStakingPool();
    }

    /**
     * @dev Actualiza la información de un pool de staking (soloOwner).
     * @param _pid ID del pool.
     */
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number < pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0){
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 tokenReward = multiplier.mul(n2drPerBlock).mul(pool.allocPoint).div(totalAllocation);
        n2dr.mint(dev, tokenReward.div(10));
        n2dr.mint(address(n2drpay), tokenReward);
        pool.rewardTokenPerShare = pool.rewardTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));//1e12 szabo unidad de valor eth
        pool.lastRewardBlock = block.number;
    }

    /**
     * @dev Actualiza todos los pools de staking.
     */
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for(uint256 pid; pid < length; pid++){
            updatePool(pid);
        }
    }

    /**
     * @dev Establece la asignación de puntos para un pool de staking existente (soloOwner).
     * @param _pid ID del pool.
     * @param _allocPoint Nueva asignación de puntos para el pool.
     * @param _withUpdate Si se debe actualizar la información de los pools antes de establecer la nueva asignación.
     */
    function set(uint256 _pid, uint256 _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if(prevAllocPoint != _allocPoint){
            totalAllocation = totalAllocation.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    /**
     * @dev Calcula las recompensas pendientes para un usuario en un pool específico.
     * @param _pid ID del pool.
     * @param _user Dirección del usuario.
     * @return Recompensas pendientes para el usuario en el pool.
     */
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 rewardTokenPerShare = pool.rewardTokenPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if(block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 tokenReward = multiplier.mul(n2drPerBlock).mul(pool.allocPoint).div(totalAllocation);
            rewardTokenPerShare = rewardTokenPerShare.add(tokenReward.mul(1e12).div(lpSupply));
        }

        return user.amount.mul(rewardTokenPerShare).div(1e12).sub(user.pendingReward);
    }

    /**
     * @dev Deposita tokens en un pool de staking.
     * @param _pid ID del pool.
     * @param _amount Cantidad de tokens a depositar.
     */
    function stake(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0 ) {
            uint256 pending = user.amount.mul(pool.rewardTokenPerShare).div(1e12).sub(user.pendingReward);
            if(pending > 0 ) {
                safeN2drTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.pendingReward = user.amount.mul(pool.rewardTokenPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    /**
     * @dev Retira tokens de un pool de staking.
     * @param _pid ID del pool.
     * @param _amount Cantidad de tokens a retirar.
     */
    function unstake(uint256 _pid, uint256 _amount) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0 ) {
            uint256 pending = user.amount.mul(pool.rewardTokenPerShare).div(1e12).sub(user.pendingReward);
            if(pending > 0 ) {
                safeN2drTransfer(msg.sender, pending);
            }
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.pendingReward = user.amount.mul(pool.rewardTokenPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /**
     * @dev Reinvierte automáticamente las recompensas en el pool principal.
     */
    function autoCompound() public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[0][msg.sender];
        updatePool(0);  
         if (user.amount > 0 ) {
            uint256 pending = user.amount.mul(pool.rewardTokenPerShare).div(1e12).sub(user.pendingReward);
            if(pending > 0 ) {
              user.amount = user.amount.add(pending);
            }
         }
         user.pendingReward = user.amount.mul(pool.rewardTokenPerShare).div(1e12);
    }

    /**
     * @dev Retira todos los fondos de un pool de staking de forma inmediata.
     * @param _pid ID del pool.
     */
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender]; 
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.pendingReward = 0;
    }

    /**
     * @dev Cambia la dirección del desarrollador (solo el desarrollador actual puede llamar a esta función).
     * @param _dev Nueva dirección del desarrollador.
     */
    function changeDev(address _dev) public {
        require(msg.sender == dev, "Not Authorized");
        dev = _dev;
    }

    /**
     * @dev Transfiere tokens N2DR de forma segura utilizando el contrato de pagos N2D.
     * @param _to Dirección del destinatario.
     * @param _amount Cantidad de tokens a transferir.
     */
    function safeN2drTransfer(address _to, uint256 _amount) internal {
        n2drpay.safeN2drTransfer(_to, _amount);
    }
}
