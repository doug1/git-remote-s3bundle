
git-remote-s3bundle
===================

This is a git remote protocol helper module for git bundles stored in Amazon S3.
See man git-bundle(1) for more info on bundles.

It supports clone, fetch, and pull from complete bundles built using:

``
git bundle create filename.bundle --all
``

AWS REST Authentication uses credential from the environment or IAM role
credentials from the EC2 metadata server.

Install as "git-remote-s3bundle" (without extension) anywhere on PATH,
or in your favorite local/libexec location.

Clone a repo using:

``
git clone s3bundle://bucket/path/reponame.bundle reponame-local
``

