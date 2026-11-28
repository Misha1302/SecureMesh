using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280103_VerificationEmailBudget")]
public sealed class VerificationEmailBudgetMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        CREATE TABLE verification_email_budget (
            singleton boolean PRIMARY KEY CHECK (singleton),
            hour_started_at timestamptz NOT NULL,
            attempts integer NOT NULL CHECK (attempts > 0)
        );
        """);

    protected override void Down(MigrationBuilder migrationBuilder) =>
        migrationBuilder.Sql("DROP TABLE verification_email_budget;");
}
