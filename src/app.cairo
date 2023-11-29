use dojo::world::{IWorldDispatcher, IWorldDispatcherTrait};
use pixelaw::core::models::pixel::{Pixel, PixelUpdate};
use pixelaw::core::utils::{get_core_actions, Direction, Position, DefaultParameters};
use starknet::{get_caller_address, get_contract_address, get_execution_info, ContractAddress};

#[derive(Serde, Copy, Drop, PartialEq, Introspect)]
enum State {
    None: (),
    Open: (),
    Finished: ()
}

#[derive(Model, Copy, Drop, Serde, SerdeLen)]
struct Game {
    #[key]
    x: u64,
    #[key]
    y: u64,
    id: u32,
    creator: ContractAddress,
    state: State,
    size: u64,
    mines_amount: u64,
    started_timestamp: u64
}  

#[starknet::interface]
trait IMinesweeperActions<TContractState> {
    fn init(self: @TContractState);
    fn interact(self: @TContractState, default_params: DefaultParameters, size: u64, mines_amount: u64);
    fn reveal(self: @TContractState, default_params: DefaultParameters);
    fn explode(self: @TContractState, default_params: DefaultParameters);
    fn ownerless_space(self: @TContractState, default_params: DefaultParameters, size: u64) -> bool;
}

/// APP_KEY must be unique across the entire platform
const APP_KEY: felt252 = 'minesweeper';

/// Core only supports unicode icons for now
const APP_ICON: felt252 = 'U+1F4A3'; // bomb

/// prefixing with BASE means using the server's default manifest.json handler
const APP_MANIFEST: felt252 = 'BASE/manifests/minesweeper';

/// The maximum duration of a game in milliseconds
const GAME_MAX_DURATION: u64 = 20000;

#[dojo::contract]
/// contracts must be named as such (APP_KEY + underscore + "actions")
mod minesweeper_actions {
    use starknet::{
        get_tx_info, get_caller_address, get_contract_address, get_execution_info, ContractAddress
    };

    use super::IMinesweeperActions;
    use pixelaw::core::models::pixel::{Pixel, PixelUpdate};

    use pixelaw::core::models::permissions::{Permission};
    use pixelaw::core::actions::{
        IActionsDispatcher as ICoreActionsDispatcher,
        IActionsDispatcherTrait as ICoreActionsDispatcherTrait
    };
    use super::{Game, State};
    use super::{APP_KEY, APP_ICON, APP_MANIFEST, GAME_MAX_DURATION};
    use pixelaw::core::utils::{get_core_actions, Direction, Position, DefaultParameters};

    use debug::PrintTrait;

    use poseidon::poseidon_hash_span;

    #[derive(Drop, starknet::Event)]
    struct GameOpened {
        game_id: u32,
        creator: ContractAddress
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        GameOpened: GameOpened
    }


    fn subu8(nr: u8, sub: u8) -> u8 {
        if nr >= sub {
            return nr - sub;
        } else {
            return 0;
        }
    }


    // ARGB
    // 0xFF FF FF FF
    // empty: 0x 00 00 00 00
    // normal color: 0x FF FF FF FF

    fn encode_color(r: u8, g: u8, b: u8) -> u32 {
        (r.into() * 0x10000) + (g.into() * 0x100) + b.into()
    }

    fn decode_color(color: u32) -> (u8, u8, u8) {
        let r = (color / 0x10000);
        let g = (color / 0x100) & 0xff;
        let b = color & 0xff;

        (r.try_into().unwrap(), g.try_into().unwrap(), b.try_into().unwrap())
    }

    // impl: implement functions specified in trait
    #[external(v0)]
    impl ActionsImpl of IMinesweeperActions<ContractState> {
        /// Initialize the MyApp App (TODO I think, do we need this??)
        fn init(self: @ContractState) {
            let world = self.world_dispatcher.read();
            let core_actions = pixelaw::core::utils::get_core_actions(world);

            core_actions.update_app(APP_KEY, APP_ICON, APP_MANIFEST);

            // TODO: replace this with proper granting of permission
            
            core_actions.update_permission('snake',
                Permission {
                    alert: false,
                    app: false,
                    color: true,
                    owner: false,
                    text: true,
                    timestamp: false,
                    action: false
                });
            core_actions.update_permission('paint',
                Permission {
                    alert: false,
                    app: false,
                    color: true,
                    owner: false,
                    text: true,
                    timestamp: false,
                    action: false
                });     
        }


        /// Put color on a certain position
        ///
        /// # Arguments
        ///
        /// default_params: Default parameters for the action
        /// size: Size of the board
        /// mines_amount: Amount of mines to place
        fn interact(self: @ContractState, default_params: DefaultParameters, size: u64, mines_amount: u64) {
            'put_color'.print();

            // Load important variables
            let world = self.world_dispatcher.read();
            let core_actions = get_core_actions(world);
            let position = default_params.position;
            let player = core_actions.get_player_address(default_params.for_player);
            let system = core_actions.get_system_address(default_params.for_system);

            // Load the Pixel
            let mut pixel = get!(world, (position.x, position.y), (Pixel));

            let caller_address = get_caller_address();
            let mut game = get!(world, (position.x, position.y), (Game));
            let timestamp = starknet::get_block_timestamp();

            if (pixel.alert == 'reveal') {
                // call reveal function
                self.reveal(default_params);
            } else if (pixel.alert == 'explode') {
                // call explode function
                self.explode(default_params);
            } else if (self.ownerless_space(default_params, size: size) == true ){
                // start a new game
                let mut id = world.uuid();
                game = 
                    Game {
                        x: position.x,
                        y: position.y,
                        id,
                        creator: player,
                        state: State::Open,
                        size: size,
                        mines_amount: mines_amount,
                        started_timestamp: timestamp
                    };

                'Here Game Declare'.print();

                emit!(world, GameOpened {game_id: game.id, creator: player});

                'Emit Done'.print();

                set!(world, (game));

                'Set Game Done'.print();

                let mut i: u64 = 0;
				let mut j: u64 = 0;

                loop { 
					if i >= size {
						break;
					}
					j = 0;
					loop { 
						if j >= size {
							break;
						}
						core_actions
							.update_pixel(
							player,
							system,
							PixelUpdate {
								x: position.x + j,
								y: position.y + i,
								color: Option::Some(default_params.color), //should I pass in a color to define the minesweepers field color?
								alert: Option::Some('reveal'),
								timestamp: Option::None,
								text: Option::None,
								app: Option::Some(system),
								owner: Option::Some(player),
								action: Option::None,
								}
							);
							j += 1;
					};
					i += 1;
				};

				let mut random_number: u256 = 0;

				let mut num_mines = 0;
				loop {
					if num_mines >= mines_amount {
						break;
					}
					let timestamp_felt252 = timestamp.into();
					let x_felt252 = position.x.into();
					let y_felt252 = position.y.into();
					let m_felt252 = num_mines.into();

					//random = (timestamp + i) + position.x.into() + position.y.into();

					let hash: u256 = poseidon_hash_span(array![timestamp_felt252, x_felt252, y_felt252, m_felt252].span()).into();
					random_number = hash % (size * size).into();

                    core_actions
                        .update_pixel(
                            player,
                            system,
                            PixelUpdate {
                                //x: (position.x + random_x),
                                x: position.x + (random_number / size.into()).try_into().unwrap(),
                                //y: (position.y + random_y),
                                y: position.y + (random_number % size.into()).try_into().unwrap(),
                                color: Option::Some(default_params.color),
                                alert: Option::Some('explode'),
                                timestamp: Option::None,
                                text: Option::None,
                                app: Option::Some(system),
                                owner: Option::Some(player),
                                action: Option::None,
                            }
                        );
                    num_mines += 1;
                };

            } else {
                // we can't do anything, so we just return
                'find a free area'.print();
            }


            // TODO: Load MyApp App Settings like the fade steptime
            // For example for the Cooldown feature
            let COOLDOWN_SECS = 5;

            // Check if 5 seconds have passed or if the sender is the owner
            // TODO error message confusing, have to split this
            assert(
                pixel.owner.is_zero() || (pixel.owner) == player || starknet::get_block_timestamp()
                    - pixel.timestamp < COOLDOWN_SECS,
                'Cooldown not over'
            );

            // We can now update color of the pixel
            core_actions
                .update_pixel(
                    player,
                    system,
                    PixelUpdate {
                        x: position.x,
                        y: position.y,
                        color: Option::Some(default_params.color),
                        alert: Option::None,
                        timestamp: Option::None,
                        text: Option::None,
                        app: Option::Some(system),
                        owner: Option::Some(player),
                        action: Option::None // Not using this feature for myapp
                    }
                );

            'put_color DONE'.print();
        }

        /// Reveal a pixel on a certain position
        ///
        /// # Arguments
        /// default_params: Default parameters for the action
        fn reveal(self: @ContractState, default_params: DefaultParameters) {
            let world = self.world_dispatcher.read();
            let core_actions = get_core_actions(world);
            let position = default_params.position;
            let player = core_actions.get_player_address(default_params.for_player);
            let system = core_actions.get_system_address(default_params.for_system);
            let mut pixel = get!(world, (position.x, position.y), (Pixel));

			core_actions
				.update_pixel(
					player,
					system,
					PixelUpdate {
						x: position.x,
						y: position.y,
						color: Option::Some(default_params.color),
						alert: Option::None,
						timestamp: Option::None,
						text: Option::Some('U+1F30E'),
						app: Option::None,
						owner: Option::None,
						action: Option::None,
					}
				);
        }

        /// Explode a pixel on a certain position
        ///
        /// # Arguments
        /// default_params: Default parameters for the action
        fn explode(self: @ContractState, default_params: DefaultParameters) {
            let world = self.world_dispatcher.read();
            let core_actions = get_core_actions(world);
            let position = default_params.position;
            let player = core_actions.get_player_address(default_params.for_player);
            let system = core_actions.get_system_address(default_params.for_system);
            let mut pixel = get!(world, (position.x, position.y), (Pixel));

			core_actions
				.update_pixel(
					player,
					system,
					PixelUpdate {
						x: position.x,
						y: position.y,
						color: Option::Some(default_params.color),
						alert: Option::None,
						timestamp: Option::None,
						text: Option::Some('U+1F4A3'),
						app: Option::None,
						owner: Option::None,
						action: Option::None,
					}
				);
        }

        /// Check if a certain position is ownerless
        ///
        /// # Arguments
        /// default_params: Default parameters for the action
        /// size: Size of the board
        fn ownerless_space(self: @ContractState, default_params: DefaultParameters, size: u64) -> bool {
			let world = self.world_dispatcher.read();
            let core_actions = get_core_actions(world);
            let position = default_params.position;
            let mut pixel = get!(world, (position.x, position.y), (Pixel));

			let mut i: u64 = 0;
			let mut j: u64 = 0;
			let mut check_test: bool = true;

			let check = loop {
				if !(pixel.owner.is_zero() && i <= size)
				{
					break false;
				}
				pixel = get!(world, (position.x, (position.y + i)), (Pixel));
				j = 0;
				loop {
					if !(pixel.owner.is_zero() && j <= size)
					{
						break false;
					}
					pixel = get!(world, ((position.x + j), position.y), (Pixel));
					j += 1;
				};
				i += 1;
				break true;
			};
			check
		}




        // /// Put color on a certain position
        // ///
        // /// # Arguments
        // ///
        // /// * `position` - Position of the pixel.
        // /// * `new_color` - Color to set the pixel to.
        // fn fade(self: @ContractState, default_params: DefaultParameters) {
        //     'fade'.print();

        //     let world = self.world_dispatcher.read();
        //     let core_actions = get_core_actions(world);
        //     let position = default_params.position;
        //     let player = core_actions.get_player_address(default_params.for_player);
        //     let system = core_actions.get_system_address(default_params.for_system);
        //     let pixel = get!(world, (position.x, position.y), Pixel);

        //     let (r, g, b) = decode_color(pixel.color);

        //     // If the color is 0,0,0 , let's stop the process, fading is done.
        //     if r == 0 && g == 0 && b == 0 {
        //         'fading is done'.print();

        //         return;
        //     }

        //     // Fade the color
        //     let FADE_STEP = 5;
        //     let new_color = encode_color(
        //         subu8(r, FADE_STEP), subu8(g, FADE_STEP), subu8(b, FADE_STEP)
        //     );

        //     let FADE_SECONDS = 0;

        //     // We implement fading by scheduling a new put_fading_color
        //     let queue_timestamp = starknet::get_block_timestamp() + FADE_SECONDS;
        //     let mut calldata: Array<felt252> = ArrayTrait::new();

        //     let THIS_CONTRACT_ADDRESS = get_contract_address();

        //     // Calldata[0]: Calling player
        //     calldata.append(player.into());

        //     // Calldata[1]: Calling system
        //     calldata.append(THIS_CONTRACT_ADDRESS.into());

        //     // Calldata[2,3] : Position[x,y]
        //     calldata.append(position.x.into());
        //     calldata.append(position.y.into());

        //     // Calldata[4] : Color
        //     calldata.append(new_color.into());

        //     core_actions
        //         .schedule_queue(
        //             queue_timestamp, // When to fade next
        //             THIS_CONTRACT_ADDRESS, // This contract address
        //             get_execution_info().unbox().entry_point_selector, // This selector
        //             calldata.span() // The calldata prepared
        //         );
        //     'put_fading_color DONE'.print();
        // }
    }
}
