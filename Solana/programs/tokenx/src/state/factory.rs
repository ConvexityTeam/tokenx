use anchor_lang::prelude::*;
use crate::constants::*;

#[account]
#[derive(InitSpace)]
pub struct Factory {
    /// Platform-level admin — can pause/unpause the factory and grant deployer rights.
    pub admin: Pubkey,
    /// When true no new suites can be deployed.
    pub paused: bool,
    /// Running count of all token suites deployed through this factory.
    pub total_deployments: u64,
    pub bump: u8,
}

impl Factory {
    pub const SPACE: usize = 8 + FACTORY_SIZE;
}
