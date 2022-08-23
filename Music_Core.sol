// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

//import "./ERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

contract Music_Core is ERC1155 {

  event Sale_Created(uint256 indexed sale_id,
    uint256[] token_ids, uint256[] amounts,
    uint256 price, uint256 limit,
    string name);
  event Sale_Ended(uint256 indexed sale_id);
  event Sale_Made(uint256 indexed sale_id, address indexed user);
  event Promo(address to, uint256 token_id, address indexed issuer);
  event Master_Created(uint256 indexed token_id, uint256 indexed ownership_token_id, string ipfs_cid);
  event Management_Changed(uint256 indexed ownership_id, address indexed new_manager);

  address controller;
  constructor(string memory url) ERC1155(url){
    entropy = uint256(keccak256(abi.encode(block.timestamp)));
    controller = msg.sender;
  }

  struct ownership {
    uint256 total_sales;
    address manager;
    bool exists;
  }

  struct master {
    uint256 ownership_token_id;
    uint256 lifetime_copies;
    uint256 lifetime_streams;
    string ipfs_cid;
    bool live;
  }

  struct sale {
    uint256[] token_ids;
    uint256[] amounts;
    uint256 price;
    uint256 limit;
    address manager;
  }


  uint256 entropy;

  mapping(uint256 => master) masters;
  /**
   * @dev See {IERC1155MetadataURI-uri}.
   *
   * This implementation returns the same URI for *all* token types. It relies
   * on the token type ID substitution mechanism
   * https://eips.ethereum.org/EIPS/eip-1155#metadata[defined in the EIP].
   *
   * Clients calling this function must replace the `\{id\}` substring with the
   * actual token type ID.
   */
  function uri(uint256 token_id) public view virtual override returns (string memory) {
      return string(abi.encodePacked("ipfs://", masters[token_id].ipfs_cid));
  }

  mapping(uint256 => ownership) ownerships;
  mapping (uint256 => sale) sales;

  mapping(address=>mapping(uint256 => uint256)) last_paid_out;
  mapping(address => uint256) owed;

  function get_master(uint256 master_id) public view returns(master memory){
    return masters[master_id];
  }
  function get_sale(uint256 sale_id) public view returns (sale memory){
    return sales[sale_id];
  }

  function rand() internal returns(uint256) {
    entropy = uint256(keccak256(abi.encode(entropy, msg.sender, block.timestamp)));
    return entropy;
  }

  function change_controller(address new_controller) public {
    require(msg.sender == controller, "not controller");
    controller = new_controller;
  }

  function create_master(string calldata ipfs_cid) public {
    uint256 token_id = uint256(keccak256(abi.encode(ipfs_cid)));
    require(msg.sender == controller, "not controller");
    require(masters[token_id].ownership_token_id == 0, "master exists");

    uint256 ownership_token_id = rand();

    // generate a new ownership_token_id
    _mint(msg.sender, ownership_token_id, 10000, "0x00");

    masters[token_id].ownership_token_id = ownership_token_id;
    masters[token_id].live = true;
    masters[token_id].ipfs_cid = ipfs_cid;

    ownerships[ownership_token_id].manager = msg.sender;
    ownerships[ownership_token_id].exists = true;

    emit Master_Created(token_id, ownership_token_id, ipfs_cid);
  }

  function gift_promo(address to, uint256 token_id) public {
    require(masters[token_id].live, "master is dead or doesn't exist");
    require(ownerships[masters[token_id].ownership_token_id].manager == msg.sender, "not manager");
    _mint(to, token_id, 1, "0x00");
    emit Promo(to, token_id, msg.sender);
  }

  function create_sale(string calldata name,uint256[] memory token_ids, uint256[] memory amounts, uint256 price, uint256 limit) public {
    require(limit > 0, "limit must be greater than zero");
    uint256 sale_id = rand();
    require(token_ids.length == amounts.length, "array length mismatch");

    for(uint256 token_idx = 0; token_idx < token_ids.length;  token_idx++){
      require(masters[token_ids[token_idx]].live, "master is not live");
      require(ownerships[masters[token_ids[token_idx]].ownership_token_id].manager == msg.sender, "not manager");
    }

    sales[sale_id] = sale(token_ids, amounts, price, limit, msg.sender);
    emit Sale_Created(sale_id, token_ids, amounts, price, limit, name);
  }

  function stop_sale(uint256 sale_id) public {
    require(sales[sale_id].manager == msg.sender, "not manager");
    require(sales[sale_id].limit > 0);
    delete(sales[sale_id]);
    emit Sale_Ended(sale_id);
  }

  // anyone who gets > 50% in 24 hr
  // transfers can't continue for ownership until complete or 24 hours have passed
  function assign_manager(uint256 ownership_id, address new_manager) public {
      require(ownerships[ownership_id].manager == msg.sender, "not manager");
      ownerships[ownership_id].manager = new_manager;
      emit Management_Changed(ownership_id, new_manager);
  }

  function kill_master(uint256 token_id) public {
    require(masters[token_id].live, "master already dead");
    require(ownerships[masters[token_id].ownership_token_id].manager == msg.sender, "not manager");
    masters[token_id].live = false;
  }

    mapping (uint256 => uint256) total_supplies;

  function burn(uint256 token_id, uint256 amount) public {
    _burn(msg.sender, token_id, amount);
    total_supplies[token_id]-= amount;
  }

  function buy(uint256 sale_id) public payable {
    sale memory s = sales[sale_id];
    s.limit -= 1;

    require(msg.value >= s.price, "insufficient payment");

    uint256 split = msg.value / s.token_ids.length;

    for(uint256 token_idx = 0; token_idx < s.token_ids.length;  token_idx++){
      master memory m = masters[s.token_ids[token_idx]];
      require(m.live, "master is not live");
      ownerships[m.ownership_token_id].total_sales += split;
      total_supplies[s.token_ids[token_idx]] += s.amounts[token_idx];
    }

    _mintBatch(msg.sender, s.token_ids, s.amounts, "0x00");

    emit Sale_Made(sale_id, msg.sender);
  }

  function calc_owed(address user, uint256 ownership_id) public {
    if(user != address(0) && ownerships[ownership_id].exists){

      owed[user] +=  (balanceOf(user, ownership_id) * (ownerships[ownership_id].total_sales - last_paid_out[user][ownership_id]))
      / total_supplies[ownership_id];
      last_paid_out[user][ownership_id] = ownerships[ownership_id].total_sales;
    }
  }

  function get_owed(address user) public view returns(uint256){
    return owed[user];
  }
  function withdraw_owed() external {
    uint256 to_pay = owed[msg.sender];
    owed[msg.sender] = 0;
    (bool sent,) = msg.sender.call{value: to_pay}("");
    require(sent, "Failed to send Ether");
  }

  /**
   * @dev See {IERC1155-balanceOfBatch_single_user}.
   */
  function balanceOfBatch_single_user(address account, uint256[] memory ids)
      external
      view
      returns (uint256[] memory)
  {

      uint256[] memory batchBalances = new uint256[](ids.length);

      for (uint256 i = 0; i < ids.length; ++i) {
          batchBalances[i] = balanceOf(account, ids[i]);
      }

      return batchBalances;
  }

  function _beforeTokenTransfer(
      address,
      address from,
      address to,
      uint256[] memory ids,
      uint256[] memory,
      bytes memory
  ) internal override {
    for(uint256 token_idx = 0; token_idx < ids.length; token_idx++){
      calc_owed(from, ids[token_idx]);
      calc_owed(to, ids[token_idx]);
    }

  }

}
