using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.EntityFrameworkCore.Migrations;

namespace SecureMesh;

[DbContext(typeof(MeshDb))]
[Migration("202611280104_DirectoryPackageOffer")]
public sealed class DirectoryPackageOfferMigration : Migration
{
    protected override void Up(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        ALTER TABLE key_packages ADD COLUMN offered_for uuid REFERENCES chat_requests(id) ON DELETE CASCADE;
        CREATE INDEX key_packages_offer ON key_packages(offered_for,device_id) WHERE lease_id IS NULL;
        """);

    protected override void Down(MigrationBuilder migrationBuilder) => migrationBuilder.Sql("""
        DROP INDEX key_packages_offer;
        ALTER TABLE key_packages DROP COLUMN offered_for;
        """);
}
