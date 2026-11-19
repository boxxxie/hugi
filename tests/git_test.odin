package hugi_tests

import hugi "../hugi"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_resolve_git_commit_all_layouts :: proc(t: ^testing.T) {
	tmp, mk_err := os.make_directory_temp("", "hugi-git-test-*", context.allocator)
	testing.expectf(t, mk_err == nil && tmp != "", "create temp git test dir: %v", mk_err)
	if mk_err != nil || tmp == "" {
		return
	}
	defer {
		_ = os.remove_all(tmp)
		delete(tmp)
	}

	write_fixture :: proc(t: ^testing.T, base: string, rel_parts: []string, content: string) {
		all := make([]string, 1 + len(rel_parts), context.temp_allocator)
		all[0] = base
		copy(all[1:], rel_parts)
		full, _ := filepath.join(all, context.temp_allocator)
		parent := filepath.dir(full)
		if !os.is_dir(parent) {
			mkp_err := os.make_directory_all(parent)
			testing.expectf(t, mkp_err == nil, "mkdir parent %s: %v", parent, mkp_err)
		}
		testing.expect(
			t,
			os.write_entire_file(full, transmute([]u8)content) == nil,
			"write git fixture",
		)
	}

	// 1. Directory outside any Git repository returns "unknown".
	outside, _ := filepath.join({tmp, "outside", "sub"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(outside) == nil, "mkdir outside")
	c_out := hugi.resolve_git_commit(outside, context.allocator)
	testing.expect_value(t, c_out, "unknown")
	delete(c_out)

	// 2. Standard .git/HEAD symref + loose branch file resolved from nested subdirectory.
	std_repo, _ := filepath.join({tmp, "std_repo"}, context.temp_allocator)
	write_fixture(t, std_repo, {".git", "HEAD"}, "ref: refs/heads/main\n")
	write_fixture(
		t,
		std_repo,
		{".git", "refs", "heads", "main"},
		"11223344556677889900aabbccddeeff00112233\n",
	)
	std_sub, _ := filepath.join({std_repo, "sub", "deep"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(std_sub) == nil, "mkdir std_sub")
	c_std := hugi.resolve_git_commit(std_sub, context.allocator)
	testing.expect_value(t, c_std, "112233445566")
	delete(c_std)

	// 3. Detached HEAD with raw 40-char SHA returns 12-char prefix.
	det_repo, _ := filepath.join({tmp, "det_repo"}, context.temp_allocator)
	write_fixture(t, det_repo, {".git", "HEAD"}, "abcdef0123456789abcdef0123456789abcdef01\n")
	c_det := hugi.resolve_git_commit(det_repo, context.allocator)
	testing.expect_value(t, c_det, "abcdef012345")
	delete(c_det)

	// 4. packed-refs fallback with comments and peeled tag annotations.
	pk_repo, _ := filepath.join({tmp, "packed_repo"}, context.temp_allocator)
	write_fixture(t, pk_repo, {".git", "HEAD"}, "ref: refs/heads/topic\n")
	write_fixture(
		t,
		pk_repo,
		{".git", "packed-refs"},
		"# pack-refs with: peeled fully-peeled sorted \n" +
		"0000111122223333444455556666777788889999 refs/tags/v0.1\n" +
		"^aaaa1111bbbb2222cccc3333dddd4444eeee5555\n" +
		"99887766554433221100ffeeddccbbaa99887766 refs/heads/topic\n",
	)
	c_pk := hugi.resolve_git_commit(pk_repo, context.allocator)
	testing.expect_value(t, c_pk, "998877665544")
	delete(c_pk)

	// 5. Linked worktree (.git file with gitdir: + commondir pointing to main .git/packed-refs).
	main_repo, _ := filepath.join({tmp, "main_repo"}, context.temp_allocator)
	write_fixture(
		t,
		main_repo,
		{".git", "packed-refs"},
		"fedcba9876543210fedcba9876543210fedcba98 refs/heads/wt-branch\n",
	)
	write_fixture(
		t,
		main_repo,
		{".git", "worktrees", "wt1", "HEAD"},
		"ref: refs/heads/wt-branch\n",
	)
	write_fixture(t, main_repo, {".git", "worktrees", "wt1", "commondir"}, "../..\n")
	wt_dir, _ := filepath.join({tmp, "wt_checkout"}, context.temp_allocator)
	write_fixture(t, wt_dir, {".git"}, "gitdir: ../main_repo/.git/worktrees/wt1\n")
	wt_sub, _ := filepath.join({wt_dir, "pkg", "mod"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(wt_sub) == nil, "mkdir wt_sub")
	c_wt := hugi.resolve_git_commit(wt_sub, context.allocator)
	testing.expect_value(t, c_wt, "fedcba987654")
	delete(c_wt)
}
