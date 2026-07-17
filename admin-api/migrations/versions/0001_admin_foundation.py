"""Create operator sessions and immutable audit history."""
from alembic import op
import sqlalchemy as sa

revision = "0001_admin_foundation"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "operators",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("subject", sa.String(255), nullable=False, unique=True),
        sa.Column("display_name", sa.String(255), nullable=False),
        sa.Column("role", sa.String(32), nullable=False),
        sa.Column("password_hash", sa.String(512)),
        sa.Column("enabled", sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_login_at", sa.DateTime(timezone=True)),
    )
    op.create_table(
        "operator_sessions",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("operator_id", sa.String(36), sa.ForeignKey("operators.id", ondelete="CASCADE"), nullable=False),
        sa.Column("token_hash", sa.String(64), nullable=False, unique=True),
        sa.Column("csrf_hash", sa.String(64), nullable=False),
        sa.Column("source_ip", sa.String(64), nullable=False),
        sa.Column("user_agent", sa.String(512), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_table(
        "audit_events",
        sa.Column("id", sa.String(36), primary_key=True),
        sa.Column("sequence", sa.Integer(), nullable=False, unique=True),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("actor_id", sa.String(255)),
        sa.Column("actor_role", sa.String(32)),
        sa.Column("source_ip", sa.String(64), nullable=False),
        sa.Column("correlation_id", sa.String(64), nullable=False),
        sa.Column("action", sa.String(128), nullable=False),
        sa.Column("target", sa.String(512), nullable=False),
        sa.Column("result", sa.String(32), nullable=False),
        sa.Column("metadata_json", sa.Text(), nullable=False),
        sa.Column("previous_hash", sa.String(64), nullable=False),
        sa.Column("event_hash", sa.String(64), nullable=False, unique=True),
    )
    op.create_index("ix_audit_events_action", "audit_events", ["action"])
    op.create_index("ix_audit_events_target", "audit_events", ["target"])
    op.create_index("ix_audit_events_correlation_id", "audit_events", ["correlation_id"])
    op.create_index("ix_audit_occurred_sequence", "audit_events", ["occurred_at", "sequence"])
    if op.get_bind().dialect.name == "postgresql":
        op.execute("""
            CREATE FUNCTION reject_audit_mutation() RETURNS trigger AS $$
            BEGIN RAISE EXCEPTION 'audit_events are immutable'; END;
            $$ LANGUAGE plpgsql
        """)
        op.execute("""
            CREATE TRIGGER audit_events_immutable BEFORE UPDATE OR DELETE ON audit_events
            FOR EACH ROW EXECUTE FUNCTION reject_audit_mutation();
        """)
    else:
        op.execute("CREATE TRIGGER audit_events_no_update BEFORE UPDATE ON audit_events BEGIN SELECT RAISE(FAIL, 'audit_events are immutable'); END")
        op.execute("CREATE TRIGGER audit_events_no_delete BEFORE DELETE ON audit_events BEGIN SELECT RAISE(FAIL, 'audit_events are immutable'); END")


def downgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        op.execute("DROP TRIGGER IF EXISTS audit_events_immutable ON audit_events")
        op.execute("DROP FUNCTION IF EXISTS reject_audit_mutation()")
    op.drop_table("audit_events")
    op.drop_table("operator_sessions")
    op.drop_table("operators")
