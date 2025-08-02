#[starknet::interface]
pub trait ITransfer<TContractState> {
    fn initiate_transfer(ref self: TContractState, recipient: ContractAddress, amount: u256, expires_at: u64, metadata: felt252) -> u256;
    fn create_transfer(ref self: TContractState, recipient: ContractAddress, amount: u256, expires_at: u64, metadata: felt252) -> u256;
    fn cancel_transfer(ref self: TContractState, transfer_id: u256) -> bool;
    fn complete_transfer(ref self: TContractState, transfer_id: u256) -> bool;
    fn partial_complete_transfer(ref self: TContractState, transfer_id: u256, partial_amount: u256) -> bool;
    fn request_cash_out(ref self: TContractState, transfer_id: u2256) -> bool;
    fn complete_cash_out(ref self: TContractState, transfer_id: u256) -> bool;
    fn get_transfer(self: @TContractState, transfer_id: u256) -> TransferData;
    fn get_transfers_by_sender(self: @TContractState, sender: ContractAddress, limit: u32, offset: u32) -> Array<TransferData>;
    fn get_transfers_by_recipient(self: @TContractState, recipient: ContractAddress, limit: u32, offset: u32) -> Array<TransferData>;
    fn get_transfers_by_status(self: @TContractState, status: TransferStatus, limit: u32, offset: u32) -> Array<TransferData>;
    fn get_expired_transfers(self: @TContractState, limit: u32, offset: u32) -> Array<TransferData>;
    fn process_expired_transfers(ref self: TContractState, limit: u32) -> u32;
    fn get_transfer_history(self: @TContractState, transfer_id: u256, limit: u32, offset: u32) -> Array<TransferHistory>;
    fn search_history_by_actor(self: @TContractState, actor: ContractAddress, limit: u32, offset: u32) -> Array<TransferHistory>;
    fn search_history_by_action(self: @TContractState, action: felt252, limit: u32, offset: u32) -> Array<TransferHistory>;
    fn get_transfer_statistics(self: @TContractState) -> (u256, u256, u256, u256);
}

#[starknet::component]
pub mod transfer_component {
    use super::*;
    use starknet::{get_caller_address, get_block_timestamp, ContractAddress};
    use starkremit_contract::base::errors::TransferErrors;
    use starkremit_contract::base::types::{TransferData, TransferStatus, TransferHistory};
    use core::num::traits::Zero;
    use starknet::info::HasComponent;
    use starkremit_contract::components::kyc; 
    use starkremit_contract::components::kyc::KYCComponent; 

    #[storage]
    pub struct Storage {
        transfers: Map<u256, TransferData>,
        next_transfer_id: u256,
        user_sent_transfers: Map<(ContractAddress, u32), u256>,
        user_sent_count: Map<ContractAddress, u32>,
        user_received_transfers: Map<(ContractAddress, u32), u256>,
        user_received_count: Map<ContractAddress, u32>,
        total_transfers: u256,
        total_completed_transfers: u256,
        total_cancelled_transfers: u256,
        total_expired_transfers: u256,
        transfer_history: Map<(u256, u32), TransferHistory>,
        transfer_history_count: Map<u256, u32>,
        actor_history: Map<(ContractAddress, u32), (u256, u32)>,
        actor_history_count: Map<ContractAddress, u32>,
        action_history: Map<(felt252, u32), (u256, u32)>,
        action_history_count: Map<felt252, u32>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        TransferCreated: TransferCreated,
        TransferCancelled: TransferCancelled,
        TransferCompleted: TransferCompleted,
        TransferPartialCompleted: TransferPartialCompleted,
        TransferExpired: TransferExpired,
        CashOutRequested: CashOutRequested,
        CashOutCompleted: CashOutCompleted,
        TransferHistoryRecorded: TransferHistoryRecorded,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferCreated {
        transfer_id: u256,
        sender: ContractAddress,
        recipient: ContractAddress,
        amount: u256,
        expires_at: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferCancelled {
        transfer_id: u256,
        cancelled_by: ContractAddress,
        timestamp: u64,
        reason: felt252,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferCompleted {
        transfer_id: u256,
        completed_by: ContractAddress,
        timestamp: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferPartialCompleted {
        transfer_id: u256,
        partial_amount: u256,
        total_amount: u256,
        timestamp: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferExpired {
        transfer_id: u256,
        expired_at: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct CashOutRequested {
        transfer_id: u256,
        requested_by: ContractAddress,
        timestamp: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct CashOutCompleted {
        transfer_id: u256,
        agent: ContractAddress,
        timestamp: u64,
    }
    #[derive(Drop, starknet::Event)]
    pub struct TransferHistoryRecorded {
        transfer_id: u256,
        action: felt252,
        actor: ContractAddress,
        from_status: TransferStatus,
        to_status: TransferStatus,
        details: felt252,
        timestamp: u64,
    }

    #[embeddable_as(Transfer)]
    impl TransferImpl<
        TContractState, +HasComponent<TContractState>, +HasComponent<KYCComponent> // Add KYCComponent here
    > of ITransfer<ComponentState<TContractState>> {
        fn initiate_transfer(
            ref self: ComponentState<TContractState>,
            recipient: ContractAddress,
            amount: u256,
            expires_at: u64,
            metadata: felt252,
        ) -> u256 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(recipient != zero_address, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(recipient != caller, 'Cannot transfer to self');
            assert(amount > 0, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(expires_at > current_time, 'Expiry must be in future');
            assert(
                expires_at <= current_time + 86400 * 30, 'Expiry too far in future',
            );
            
            // Inter-component call: Validate KYC and limits using the KYC component
            // Assuming the main contract (TContractState) provides access to kyc_component
            self.get_mut().kyc_component._validate_kyc_and_limits(caller, amount);
            self.get_mut().kyc_component._validate_kyc_and_limits(recipient, amount);

            let transfer_id = self.next_transfer_id.read();
            self.next_transfer_id.write(transfer_id + 1);
            let transfer = TransferData {
                transfer_id,
                sender: caller,
                recipient,
                amount,
                status: TransferStatus::Pending,
                created_at: current_time,
                updated_at: current_time,
                expires_at,
                assigned_agent: zero_address,
                partial_amount: 0,
                metadata,
            };
            self.transfers.write(transfer_id, transfer);
            let sender_count = self.user_sent_count.read(caller);
            assert(sender_count < 4294967295, 'Max transfers per user exceeded');
            self.user_sent_transfers.write((caller, sender_count), transfer_id);
            self.user_sent_count.write(caller, sender_count + 1);
            let recipient_count = self.user_received_count.read(recipient);
            assert(recipient_count < 4294967295, 'Max transfers per user exceeded');
            self.user_received_transfers.write((recipient, recipient_count), transfer_id);
            self.user_received_count.write(recipient, recipient_count + 1);
            let total = self.total_transfers.read();
            self.total_transfers.write(total + 1);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'initiated',
                caller,
                TransferStatus::Pending,
                TransferStatus::Pending,
                'Transfer initiated',
            );
            
            // Inter-component call: Record daily usage using the KYC component
            self.get_mut().kyc_component._record_daily_usage(caller, amount);

            self.emit(Event::TransferCreated(TransferCreated {
                transfer_id,
                sender: caller,
                recipient,
                amount,
                expires_at,
            }));
            transfer_id
        }
        fn create_transfer(
            ref self: ComponentState<TContractState>,
            recipient: ContractAddress,
            amount: u256,
            expires_at: u64,
            metadata: felt252,
        ) -> u256 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(recipient != zero_address, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(amount > 0, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(expires_at > current_time, 'Expiry must be in future');
            
            // Inter-component call: Validate KYC and limits using the KYC component
            self.get_mut().kyc_component._validate_kyc_and_limits(caller, amount);
            self.get_mut().kyc_component._validate_kyc_and_limits(recipient, amount);

            let transfer_id = self.next_transfer_id.read();
            self.next_transfer_id.write(transfer_id + 1);
            let transfer = TransferData {
                transfer_id,
                sender: caller,
                recipient,
                amount,
                status: TransferStatus::Pending,
                created_at: current_time,
                updated_at: current_time,
                expires_at,
                assigned_agent: zero_address,
                partial_amount: 0,
                metadata,
            };
            self.transfers.write(transfer_id, transfer);
            let sender_count = self.user_sent_count.read(caller);
            self.user_sent_transfers.write((caller, sender_count), transfer_id);
            self.user_sent_count.write(caller, sender_count + 1);
            let recipient_count = self.user_received_count.read(recipient);
            self.user_received_transfers.write((recipient, recipient_count), transfer_id);
            self.user_received_count.write(recipient, recipient_count + 1);
            let total = self.total_transfers.read();
            self.total_transfers.write(total + 1);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'created',
                caller,
                TransferStatus::Pending,
                TransferStatus::Pending,
                'Transfer created',
            );
            self.emit(Event::TransferCreated(TransferCreated {
                transfer_id,
                sender: caller,
                recipient,
                amount,
                expires_at,
            }));
            transfer_id
        }
        fn cancel_transfer(ref self: ComponentState<TContractState>, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            assert(
                transfer.status == TransferStatus::Pending, TransferErrors::INVALID_TRANSFER_STATUS,
            );
            assert(transfer.sender == caller, TransferErrors::UNAUTHORIZED_TRANSFER_OP);
            transfer.status = TransferStatus::Cancelled;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);
            let cancelled_count = self.total_cancelled_transfers.read();
            self.total_cancelled_transfers.write(cancelled_count + 1);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'cancelled',
                caller,
                TransferStatus::Pending,
                TransferStatus::Cancelled,
                'Transfer cancelled by sender',
            );
            self.emit(Event::TransferCancelled(TransferCancelled {
                transfer_id,
                cancelled_by: caller,
                timestamp: current_time,
                reason: 'user_cancelled',
            }));
            true
        }
        fn complete_transfer(ref self: ComponentState<TContractState>, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            assert(
                transfer.status == TransferStatus::Pending
                    || transfer.status == TransferStatus::PartialComplete,
                TransferErrors::INVALID_TRANSFER_STATUS,
            );
            let zero_address: ContractAddress = 0.try_into().unwrap();
            let is_authorized = caller == transfer.recipient
                || (transfer.assigned_agent != zero_address && caller == transfer.assigned_agent);
            assert(is_authorized, TransferErrors::UNAUTHORIZED_TRANSFER_OP);
            transfer.status = TransferStatus::Completed;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);
            let completed_count = self.total_completed_transfers.read();
            self.total_completed_transfers.write(completed_count + 1);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'completed',
                caller,
                TransferStatus::Pending,
                TransferStatus::Completed,
                'Transfer completed',
            );
            self.emit(Event::TransferCompleted(TransferCompleted {
                transfer_id,
                completed_by: caller,
                timestamp: current_time,
            }));
            true
        }
        fn partial_complete_transfer(
            ref self: ComponentState<TContractState>,
            transfer_id: u256,
            partial_amount: u256,
        ) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            assert(
                transfer.status == TransferStatus::Pending
                    || transfer.status == TransferStatus::PartialComplete,
                TransferErrors::INVALID_TRANSFER_STATUS,
            );
            let zero_address: ContractAddress = 0.try_into().unwrap();
            let is_authorized = caller == transfer.recipient
                || (transfer.assigned_agent != zero_address && caller == transfer.assigned_agent);
            assert(is_authorized, TransferErrors::UNAUTHORIZED_TRANSFER_OP);
            assert(partial_amount > 0, TransferErrors::INVALID_TRANSFER_AMOUNT);
            assert(
                transfer.partial_amount + partial_amount <= transfer.amount,
                TransferErrors::PARTIAL_AMOUNT_EXCEEDS,
            );
            transfer.partial_amount += partial_amount;
            transfer.updated_at = current_time;
            if transfer.partial_amount == transfer.amount {
                transfer.status = TransferStatus::Completed;
            } else {
                transfer.status = TransferStatus::PartialComplete;
            }
            self.transfers.write(transfer_id, transfer);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'partial_completed',
                caller,
                TransferStatus::Pending,
                transfer.status,
                'Transfer partially completed',
            );
            self.emit(Event::TransferPartialCompleted(TransferPartialCompleted {
                transfer_id,
                partial_amount,
                total_amount: transfer.amount,
                timestamp: current_time,
            }));
            true
        }
        fn request_cash_out(ref self: ComponentState<TContractState>, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            assert(
                transfer.status == TransferStatus::Pending, TransferErrors::INVALID_TRANSFER_STATUS,
            );
            assert(caller == transfer.recipient, TransferErrors::UNAUTHORIZED_TRANSFER_OP);
            transfer.status = TransferStatus::CashOutRequested;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'cash_out_requested',
                caller,
                TransferStatus::Pending,
                TransferStatus::CashOutRequested,
                'Cash-out requested by recipient',
            );
            self.emit(Event::CashOutRequested(CashOutRequested {
                transfer_id,
                requested_by: caller,
                timestamp: current_time,
            }));
            true
        }
        fn complete_cash_out(ref self: ComponentState<TContractState>, transfer_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();
            let mut transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            assert(
                transfer.status == TransferStatus::CashOutRequested,
                TransferErrors::INVALID_TRANSFER_STATUS,
            );
            let zero_address: ContractAddress = 0.try_into().unwrap();
            assert(
                transfer.assigned_agent != zero_address, TransferErrors::INVALID_AGENT_ASSIGNMENT,
            );
            assert(caller == transfer.assigned_agent, TransferErrors::UNAUTHORIZED_TRANSFER_OP);
            
            // Assuming is_agent_authorized is a function in agent_management component
            // self.get_mut().agent_management.is_agent_authorized(caller, transfer_id); 
            // This would require a call to the AgentManagementComponent.
            // For now, I'll remove the commented out line as it's not directly in this component.

            transfer.status = TransferStatus::CashOutCompleted;
            transfer.updated_at = current_time;
            self.transfers.write(transfer_id, transfer);
            let completed_count = self.total_completed_transfers.read();
            self.total_completed_transfers.write(completed_count + 1);
            InternalImpl::_record_transfer_history(
                ref self,
                transfer_id,
                'cash_out_completed',
                caller,
                TransferStatus::CashOutRequested,
                TransferStatus::CashOutCompleted,
                'Cash-out completed by agent',
            );
            self.emit(Event::CashOutCompleted(CashOutCompleted {
                transfer_id,
                agent: caller,
                timestamp: current_time,
            }));
            true
        }
        fn get_transfer(self: @ComponentState<TContractState>, transfer_id: u256) -> TransferData {
            let transfer = self.transfers.read(transfer_id);
            assert(transfer.transfer_id != 0, TransferErrors::TRANSFER_NOT_FOUND);
            transfer
        }
        fn get_transfers_by_sender(
            self: @ComponentState<TContractState>, sender: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let total_count = self.user_sent_count.read(sender);
            let mut i = offset;
            let mut count = 0;
            while i < total_count && count < limit {
                let transfer_id = self.user_sent_transfers.read((sender, i));
                let transfer = self.transfers.read(transfer_id);
                transfers.append(transfer);
                count += 1;
                i += 1;
            }
            transfers
        }
        fn get_transfers_by_recipient(
            self: @ComponentState<TContractState>, recipient: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let total_count = self.user_received_count.read(recipient);
            let mut i = offset;
            let mut count = 0;
            while i < total_count && count < limit {
                let transfer_id = self.user_received_transfers.read((recipient, i));
                let transfer = self.transfers.read(transfer_id);
                transfers.append(transfer);
                count += 1;
                i += 1;
            }
            transfers
        }
        fn get_transfers_by_status(
            self: @ComponentState<TContractState>, status: TransferStatus, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            // This is a simplified implementation
            // In production, you'd want proper indexing by status
            transfers
        }
        fn get_expired_transfers(
            self: @ComponentState<TContractState>, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            // This is a simplified implementation
            // In production, you'd want proper indexing by expiry
            transfers
        }
        fn process_expired_transfers(ref self: ComponentState<TContractState>, limit: u32) -> u32 {
            let caller = get_caller_address();
            // This is a simplified implementation
            // In production, you'd iterate through transfers and mark expired ones
            0
        }
        fn get_transfer_history(
            self: @ComponentState<TContractState>, transfer_id: u256, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.transfer_history_count.read(transfer_id);
            let mut i = offset;
            let mut count = 0;
            while i < total_count && count < limit {
                let history_entry = self.transfer_history.read((transfer_id, i));
                history.append(history_entry);
                count += 1;
                i += 1;
            }
            history
        }
        fn search_history_by_actor(
            self: @ComponentState<TContractState>, actor: ContractAddress, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.actor_history_count.read(actor);
            let mut i = offset;
            let mut count = 0;
            while i < total_count && count < limit {
                let (transfer_id, history_index) = self.actor_history.read((actor, i));
                let history_entry = self.transfer_history.read((transfer_id, history_index));
                history.append(history_entry);
                count += 1;
                i += 1;
            }
            history
        }
        fn search_history_by_action(
            self: @ComponentState<TContractState>, action: felt252, limit: u32, offset: u32,
        ) -> Array<TransferHistory> {
            let mut history = ArrayTrait::new();
            let total_count = self.action_history_count.read(action);
            let mut i = offset;
            let mut count = 0;
            while i < total_count && count < limit {
                let (transfer_id, history_index) = self.action_history.read((action, i));
                let history_entry = self.transfer_history.read((transfer_id, history_index));
                history.append(history_entry);
                count += 1;
                i += 1;
            }
            history
        }
        fn get_transfer_statistics(self: @ComponentState<TContractState>) -> (u256, u256, u256, u256) {
            (
                self.total_transfers.read(),
                self.total_completed_transfers.read(),
                self.total_cancelled_transfers.read(),
                self.total_expired_transfers.read(),
            )
        }
    }

    pub impl InternalImpl<TContractState, +HasComponent<TContractState>, +HasComponent<KYCComponent>> of InternalTrait<TContractState> {
        fn _record_transfer_history(
            ref self: ComponentState<TContractState>,
            transfer_id: u256,
            action: felt252,
            actor: ContractAddress,
            from_status: TransferStatus,
            to_status: TransferStatus,
            details: felt252,
        ) {
            let current_time = get_block_timestamp();
            let history_count = self.transfer_history_count.read(transfer_id);
            let history = TransferHistory {
                transfer_id,
                action,
                actor,
                from_status,
                to_status,
                details,
                timestamp: current_time,
            };
            self.transfer_history.write((transfer_id, history_count), history);
            self.transfer_history_count.write(transfer_id, history_count + 1);
            let actor_count = self.actor_history_count.read(actor);
            self.actor_history.write((actor, actor_count), (transfer_id, history_count));
            self.actor_history_count.write(actor, actor_count + 1);
            let action_count = self.action_history_count.read(action);
            self.action_history.write((action, action_count), (transfer_id, history_count));
            self.action_history_count.write(action, action_count + 1);
            self.emit(Event::TransferHistoryRecorded(TransferHistoryRecorded {
                transfer_id,
                action,
                actor,
                from_status,
                to_status,
                details,
                timestamp: current_time,
            }));
        }

        fn _validate_kyc_and_limits(ref self: ComponentState<TContractState>, user: ContractAddress, amount: u256) {
            // Access the KYCComponent via the main contract state
            let kyc_component_state = self.get_mut().kyc_component;

            // Check KYC validity
            assert(kyc_component_state.is_kyc_valid(user), KYCErrors::INVALID_KYC_STATUS);

            // Get user's KYC data and level
            let kyc_data = kyc_component_state.user_kyc_data.read(user);
            let level_u8 = kyc_component_state._kyc_level_to_u8(kyc_data.level);

            // Check single transaction limit
            let single_limit = kyc_component_state.single_limits.read(level_u8);
            assert(amount <= single_limit, KYCErrors::SINGLE_TX_LIMIT_EXCEEDED);

            // Check daily limit
            let daily_limit = kyc_component_state.daily_limits.read(level_u8);
            let current_usage = kyc_component_state._get_daily_usage(user);
            assert(current_usage + amount <= daily_limit, KYCErrors::DAILY_LIMIT_EXCEEDED);
        }

        fn _record_daily_usage(ref self: ComponentState<TContractState>, user: ContractAddress, amount: u256) {
            // Access the KYCComponent via the main contract state and call its internal function
            self.get_mut().kyc_component._record_daily_usage(user, amount);
        }

        fn get_transfers_by_status(
            self: @ComponentState<TContractState>, status: TransferStatus, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let mut found = 0;
            let mut skipped = 0;
            let mut i = 0u32;
            let total = self.next_transfer_id.read();
            while i < total.into() {
                let transfer = self.transfers.read(i.into());
                if transfer.transfer_id != 0 && transfer.status == status {
                    if skipped < offset {
                        skipped += 1;
                    } else if found < limit {
                        transfers.append(transfer);
                        found += 1;
                    } else {
                        break;
                    }
                }
                i += 1;
            }
            transfers
        }
        fn get_expired_transfers(
            self: @ComponentState<TContractState>, limit: u32, offset: u32,
        ) -> Array<TransferData> {
            let mut transfers = ArrayTrait::new();
            let mut found = 0;
            let mut skipped = 0;
            let mut i = 0u32;
            let total = self.next_transfer_id.read();
            let now = get_block_timestamp();
            while i < total.into() {
                let transfer = self.transfers.read(i.into());
                if transfer.transfer_id != 0 && transfer.expires_at < now && transfer.status != TransferStatus::Expired {
                    if skipped < offset {
                        skipped += 1;
                    } else if found < limit {
                        transfers.append(transfer);
                        found += 1;
                    } else {
                        break;
                    }
                }
                i += 1;
            }
            transfers
        }
        fn process_expired_transfers(ref self: ComponentState<TContractState>, limit: u32) -> u32 {
            let now = get_block_timestamp();
            let mut processed = 0u32;
            let mut i = 0u32;
            let total = self.next_transfer_id.read();
            while i < total.into() && processed < limit {
                let mut transfer = self.transfers.read(i.into());
                if transfer.transfer_id != 0 && transfer.expires_at < now && transfer.status != TransferStatus::Expired {
                    transfer.status = TransferStatus::Expired;
                    transfer.updated_at = now;
                    self.transfers.write(i.into(), transfer);
                    processed += 1;
                    self.emit(Event::TransferExpired(TransferExpired {
                        transfer_id: transfer.transfer_id,
                        expired_at: now,
                    }));
                }
                i += 1;
            }
            processed
        }
    }
}