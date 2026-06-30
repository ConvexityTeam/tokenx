use anchor_lang::prelude::*;

declare_id!("56VkagdgPEgKbkaaiAiXM9REzhCwmrUTYF8hpuYDxPVH");

#[program]
pub mod tokenx {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>) -> Result<()> {
        msg!("Greetings from: {:?}", ctx.program_id);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Initialize {}
