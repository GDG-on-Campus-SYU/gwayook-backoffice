-- Apply only after the app with /consent and logged read RPCs is deployed.
update private.privacy_control set enforced=true where id;
-- Aggregated inventory views need these columns; names, operator IDs and free-text notes use the logged RPC.
revoke select on public.inventory_movements from authenticated;
grant select(id,item_id,kind,quantity,team_id,created_at) on public.inventory_movements to authenticated;
