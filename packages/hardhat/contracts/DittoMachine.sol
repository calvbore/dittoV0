pragma solidity >=0.8.0 <0.9.0;
//SPDX-License-Identifier: MIT

// import "hardhat/console.sol";
import "@rari-capital/solmate/src/tokens/ERC721.sol";
import "@rari-capital/solmate/src/utils/SafeTransferLib.sol";
import "abdk-libraries-solidity/ABDKMath64x64.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
// import "@openzeppelin/contracts/access/Ownable.sol";

contract DittoMachine is ERC721, ERC721TokenReceiver {

    using SafeCast for *;
    using ABDKMath64x64 for int128;

    bytes32 public constant FLOOR_HASH = hex'fddc260aecba8a66725ee58da4ea3cbfcf4ab6c6ad656c48345a575ca18c45c9';
    uint256 public constant BASE_TERM = 2**18;
    uint256 public constant MIN_FEE = 32;
    uint256 public constant DNOM = 2**16;

    // variables essential to calculating auction/price information for each cloneId
    struct CloneShape {
        uint256 tokenId;
        uint256 worth;
        address ERC721Contract;
        address ERC20Contract;
        uint16 heat;
        uint256 term;
    }

    mapping(uint256 => CloneShape) public cloneIdToShape;
    mapping(uint256 => uint256) public cloneIdToSubsidy;

    // mapping(uint256 => mapping(uint256 => uint256)) public cloneIdToBlockAmount;
    // mapping(uint256 => mapping(uint256 => uint256)) public cloneIdToBlockBidder;

    constructor() ERC721("Ditto", "DTO") { }

    fallback() external {
        revert();
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        // figure out what to do here eventually
        // might be neat to have some generative art?
        // or just return the the tokenURI of the original as below
        return ERC721(cloneIdToShape[id].ERC721Contract).tokenURI(cloneIdToShape[id].tokenId);
    }

    // open a future on a desired nft or floor?
    function duplicate(
        address _ERC721Contract,
        uint256 _tokenId,
        address _ERC20Contract,
        uint256 _amount,
        bool floor
    ) public {
        // ensure enough funds to do some math on
        require(_amount >= DNOM, "DM:duplicate:_amount.invalid");
        // calculate cloneId by hashing identifiying information
        uint256 cloneId = uint256(keccak256(abi.encodePacked(
            _ERC721Contract,
            (!floor ? _tokenId : uint256(FLOOR_HASH)),
            _ERC20Contract,
            floor
        )));
        uint256 value;
        uint256 subsidy;
        if ((ownerOf[cloneId]) == address(0)) {
            subsidy = (_amount * MIN_FEE / DNOM).toUint128();
            value = _amount.toUint128() - subsidy;
            cloneIdToShape[cloneId] = CloneShape(
                (!floor ? _tokenId : uint256(FLOOR_HASH)),
                value,
                _ERC721Contract,
                _ERC20Contract,
                1,
                block.timestamp + BASE_TERM
            );
            cloneIdToSubsidy[cloneId] += subsidy;
            SafeTransferLib.safeTransferFrom( // EXTERNAL CALL
                ERC20(_ERC20Contract),
                msg.sender,
                address(this),
                _amount
            );
            _safeMint(msg.sender, cloneId); // EXTERNAL CALL
        } else {
            // if a clone has already been made
            CloneShape memory cloneShape = cloneIdToShape[cloneId];
            value = cloneShape.worth;
            // calculate time until auction ends
            int128 timeLeft = (cloneShape.term - block.timestamp).toInt256().toInt128();
            uint256 minAmount = timeLeft > 0 ?
                value * uint128(timeLeft) / uint128((timeLeft << 64).sqrt() >> 64) :
                value + (value * MIN_FEE / DNOM);

            // calculate protocol fees, subsidy and worth values
            uint16 heat = cloneShape.heat;
            subsidy = minAmount * MIN_FEE * uint256(heat) / DNOM;
            value = _amount - subsidy; // will be applied to cloneShape.worth
            require(value >= minAmount, "DM:duplicate:_amount.invalid");

            // calculate new heat and clone term values
            if (timeLeft > 0) {
                heat = uint256(int256(timeLeft)) >= DNOM ? type(uint16).max :
                    heat * (uint128(timeLeft) / uint128((timeLeft << 64).sqrt() >> 64)).toUint16();
            } else {
                heat = uint128(-timeLeft) > uint128(heat) ? 0 : heat - uint128(-timeLeft).toUint16() ;
            }

            cloneIdToShape[cloneId] = CloneShape(
                cloneShape.tokenId,
                value,
                cloneShape.ERC721Contract,
                cloneShape.ERC20Contract,
                heat,
                block.timestamp + BASE_TERM
            );
            cloneIdToSubsidy[cloneId] += subsidy;
            // buying out the previous clone owner
            SafeTransferLib.safeTransferFrom( // EXTERNAL CALL
                ERC20(_ERC20Contract),
                msg.sender,
                ownerOf[cloneId],
                (cloneShape.worth + (subsidy/2 + subsidy%2))
            );
            // paying required funds to this contract
            SafeTransferLib.safeTransferFrom( // EXTERNAL CALL
                ERC20(_ERC20Contract),
                msg.sender,
                address(this),
                (value + (subsidy/2))
            );
            // force transfer from current owner to new highest bidder
            forceSafeTransferFrom(ownerOf[cloneId], msg.sender, cloneId); // EXTERNAL CALL
            assert((cloneShape.worth + (subsidy/2 + subsidy%2)) + (value + (subsidy/2)) == _amount);
        }
    }

    function dissolve(address owner, uint256 _cloneId) public {
        require(owner == ownerOf[_cloneId], "WRONG_OWNER");

        require(
            msg.sender == owner || msg.sender == getApproved[_cloneId] || isApprovedForAll[owner][msg.sender],
            "NOT_AUTHORIZED"
        );

        CloneShape memory cloneShape = cloneIdToShape[_cloneId];
        delete cloneIdToShape[_cloneId];

        _burn(_cloneId);
        SafeTransferLib.safeTransferFrom( // EXTERNAL CALL
            ERC20(cloneShape.ERC20Contract),
            msg.sender,
            owner,
            cloneShape.worth
        );
    }

    function onERC721Received(
        address,
        address from,
        uint256 id,
        bytes calldata data
    ) external returns (bytes4) {
        address ERC721Contract = msg.sender;
        (address ERC20Contract, bool floor) = abi.decode(data, (address, bool));
        uint256 cloneId = uint256(keccak256(abi.encodePacked(
            ERC721Contract,
            (!floor ? id : uint256(FLOOR_HASH)),
            ERC20Contract,
            floor
        )));

        return this.onERC721Received.selector;
    }

    // first go at implementing a forced transfer hook
    function forceTransferFrom(
        address from,
        address to,
        uint256 id
    ) private {
        // no ownership or approval checks cause we're forcing a change of ownership
        require(from == ownerOf[id], "WRONG_FROM");
        require(to != address(0), "INVALID_RECIPIENT");

        unchecked {
            balanceOf[from]--;

            balanceOf[to]++;
        }

        ownerOf[id] = to;

        delete getApproved[id];

        emit Transfer(from, to, id);
    }

    function forceSafeTransferFrom(
        address from,
        address to,
        uint256 id
    ) private {
        forceTransferFrom(from, to, id);
        // give contracts the option to account for a forced transfer
        // if they don't implement the ejector we're stll going to move the token.
        if (to.code.length != 0) {
            try ERC721TokenEjector(from).onERC721Ejected(address(this), to, id, "") {} // EXTERNAL CALL
            catch {}
        }

        require( // EXTERNAL CALL
            to.code.length == 0 ||
                ERC721TokenReceiver(to).onERC721Received(msg.sender, address(0), id, "") ==
                ERC721TokenReceiver.onERC721Received.selector,
            "UNSAFE_RECIPIENT"
        );
    }

}


interface ERC721TokenEjector {

    function onERC721Ejected(
        address operator,
        address to,
        uint256 id,
        bytes calldata data
    ) external returns (bytes4);

}
